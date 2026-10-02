import Foundation
import SQLite3

/// Minimal SQLite wrapper. Serializes all access on one queue.
/// Migrations are versioned; extend `migrate()` for v2+.
///
/// Workstream 6 (database survival): startup is a recoverable pipeline —
/// open → migrate (with pre-migration backup) → validate (integrity +
/// foreign keys). Every stage throws a structured DatabaseStartupError;
/// nothing here calls fatalError. AppContainer maps those errors to the
/// recovery UI; retry/reset live in DatabaseBoot.
final class Database {
    private let queue = DispatchQueue(label: "com.kyoku.app.database")
    /// Filesystem path of the live database file. Exposed for backup/reset
    /// (DatabaseBoot) — never mutated after init.
    let path: String
    private let db: OpaquePointer

    static let schemaVersion = 8

    /// Default on-disk location: <Application Support>/Kyoku/kyoku.sqlite.
    /// Single source of truth so Database.init and DatabaseBoot (backup /
    /// reset / recovery UI) agree on where the live file is.
    static func defaultPath() throws -> String {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Kyoku", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("kyoku.sqlite").path
    }

    init(path: String? = nil) throws {
        let resolved: String
        if let path {
            resolved = path
        } else {
            do {
                resolved = try Self.defaultPath()
            } catch {
                throw DatabaseStartupError.openFailed(detail: "\(error)")
            }
        }
        self.path = resolved

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openCode = resolved.withCString { cPath in
            sqlite3_open_v2(cPath, &handle, openFlags, nil)
        }
        guard openCode == SQLITE_OK, let opened = handle else {
            if let h = handle { sqlite3_close(h) }
            let detail: String
            if let h = handle {
                detail = String(cString: sqlite3_errmsg(h))
            } else {
                detail = "sqlite3_open_v2 failed (code \(openCode))"
            }
            throw DatabaseStartupError.openFailed(detail: detail)
        }
        // Read-only filesystem (or a directory at the DB path): sqlite3_open
        // succeeds lazily and fails later. Force the failure now with a
        // trivial write probe — a read-only location must surface as
        // openFailed, not as a half-migrated database.
        // NOTE: sqlite3_open (no _v2) would happily "open" a directory path
        // and fail obscurely later; _v2 with explicit flags keeps the
        // failure at this stage with a diagnosable message.
        self.db = opened
        do {
            // SQLite lazily creates the file; a read-only directory surfaces
            // here (e.g. "unable to open database file").
            try run("CREATE TABLE IF NOT EXISTS __kyoku_probe (id INTEGER);", [])
            try run("DROP TABLE IF EXISTS __kyoku_probe;", [])
        } catch {
            sqlite3_close(opened)
            throw DatabaseStartupError.openFailed(detail: "\(error)")
        }
        do {
            try migrate()
        } catch let startup as DatabaseStartupError {
            sqlite3_close(opened)
            throw startup
        } catch {
            sqlite3_close(opened)
            throw DatabaseStartupError.migrationFailed(
                fromVersion: (try? Self.userVersion(at: resolved)) ?? -1,
                detail: "\(error)")
        }
        do {
            try verify()
        } catch let startup as DatabaseStartupError {
            sqlite3_close(opened)
            throw startup
        } catch {
            sqlite3_close(opened)
            throw DatabaseStartupError.unrecoverable(detail: "\(error)")
        }
    }

    /// Test escape hatch: close the handle without running migrations or
    /// validation. Production never calls this — tests use it to craft
    /// fixtures (e.g. a v1-shaped file) before reopening via init(path:).
    /// The caller owns the returned handle and must sqlite3_close it.
    #if DEBUG
    static func openRaw(at path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            return nil
        }
        return opened
    }
    #endif

    /// Read PRAGMA user_version without opening a Database (for error
    /// reporting when migration itself fails).
    private static func userVersion(at path: String) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            throw DatabaseStartupError.openFailed(detail: "unable to re-open for version check")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw DatabaseStartupError.unrecoverable(detail: "version check prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseStartupError.unrecoverable(detail: "version check step failed")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Post-open health gate: integrity_check + foreign_key_check.
    /// Called at the end of init AND re-runnable by DatabaseBoot after a
    /// reset (fresh DB must verify before the app proceeds). Throws
    /// structured startup errors; logs nothing (caller logs).
    func verify() throws {
        // integrity_check returns one row per problem; single "ok" when
        // healthy. Cap at 10 rows — a badly corrupt page tree could
        // otherwise return thousands of lines into the log.
        let integrityRows = try fetch("PRAGMA integrity_check(10);", [])
        let problems = integrityRows.compactMap { $0.values.first?.text }
            .filter { $0.lowercased() != "ok" }
        if !problems.isEmpty {
            throw DatabaseStartupError.integrityFailed(
                detail: problems.prefix(5).joined(separator: "; "))
        }
        let orphans = try fetch("PRAGMA foreign_key_check;", [])
        if !orphans.isEmpty {
            let sample = orphans.prefix(3).map { row in
                let table = row["tbl_name"]?.text ?? "?"
                let rowid = row["rowid"]?.integer ?? -1
                let target = row["fkd"]?.text ?? "?"
                return "\(table):\(rowid)->\(target)"
            }.joined(separator: ", ")
            throw DatabaseStartupError.foreignKeyFailed(
                detail: "\(orphans.count) orphan row(s): \(sample)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Execute a statement with no rows expected.
    func execute(_ sql: String, _ args: [SQLiteValue] = []) throws {
        try queue.sync {
            try run(sql, args)
        }
    }

    /// Query rows, mapping each row to column name -> value.
    func query(_ sql: String, _ args: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try queue.sync {
            try fetch(sql, args)
        }
    }

    // MARK: - Migration

    /// Versioned migrations v1→v7. When an actual migration runs (current <
    /// schemaVersion), a pre-migration backup is taken FIRST via DatabaseBoot
    /// (complete before any mutation). Migration failure leaves the backup
    /// in place and surfaces DatabaseStartupError.migrationFailed — never a
    /// half-migrated live DB the app would silently continue on.
    private func migrate() throws {
        try run("PRAGMA journal_mode=WAL;", [])
        try run("PRAGMA foreign_keys=ON;", [])
        let current = (try fetch("PRAGMA user_version;", []).first?.values.first).map { $0.integer } ?? 0
        if current > Self.schemaVersion {
            // Newer than this build understands (downgrade). Refuse to run:
            // writing with an older schema path could corrupt data the newer
            // version depends on. Recovery UI explains; user can reset.
            throw DatabaseStartupError.migrationFailed(
                fromVersion: current,
                detail: "database version \(current) is newer than app schema \(Self.schemaVersion)")
        }
        if current < Self.schemaVersion, current > 0 {
            // Existing DB about to be mutated: snapshot it first. Fresh
            // (version-0) DBs skip this — there is nothing to preserve.
            // Backup failure is itself a migration failure: proceeding
            // without a safety net is worse than refusing to start.
            //
            // Ordering note: the handle is open (WAL mode set above, no
            // schema writes yet). SQLite backup API copies a consistent
            // snapshot including WAL frames; file copy would need a
            // checkpoint + close. The live connection stays usable after.
            do {
                try DatabaseBoot.backupDatabase(at: path, reason: "pre-migration-v\(current)-to-v\(Self.schemaVersion)")
            } catch {
                throw DatabaseStartupError.migrationFailed(
                    fromVersion: current,
                    detail: "pre-migration backup failed: \(error)")
            }
        }
        do {
            try runMigrations(from: current)
        } catch let startup as DatabaseStartupError {
            throw startup
        } catch {
            throw DatabaseStartupError.migrationFailed(fromVersion: current, detail: "\(error)")
        }
        if current < Self.schemaVersion {
            try run("PRAGMA user_version=\(Self.schemaVersion);", [])
        }
    }

    /// Raw migration steps, separated so migrate() owns backup + error
    /// mapping. Throws DatabaseError on statement failure.
    private func runMigrations(from current: Int) throws {
        try run("PRAGMA journal_mode=WAL;", [])
        try run("PRAGMA foreign_keys=ON;", [])
        let current = (try fetch("PRAGMA user_version;", []).first?.values.first).map { $0.integer } ?? 0
        if current < 1 {
            for stmt in Schema.v1 { try run(stmt, []) }
        }
        if current < 2 {
            // ALTER TABLE ... ADD COLUMN fails if the column exists;
            // tolerate that so re-runs and partial migrations converge.
            for stmt in Schema.v2 {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
        }
        if current < 3 {
            for stmt in Schema.v3tables { try run(stmt, []) }
            for stmt in Schema.v3columns {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
        }
        if current < 4 {
            for stmt in Schema.v4tables { try run(stmt, []) }
            for stmt in Schema.v4columns {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
        }
        if current < 5 {
            for stmt in Schema.v5columns {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
            try Schema.v5dedupe(database: self)
        }
        if current < 6 {
            for stmt in Schema.v6columns {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
        }
        if current < 7 {
            let merged = try Schema.v7dedupe(database: self)
            if merged > 0 {
                // Merged duplicates are worth one log line, not a migration
                // failure. KyokuLogger isn't available here; print is
                // appropriate for a one-time migration note.
                print("Kyoku migration v7: merged \(merged) duplicate track(s).")
            }
        }
        if current < 8 {
            // v8: imported-playlist linkage. Additive only; existing manual
            // playlists keep nil linkage (they were user-built, not imports).
            for stmt in Schema.v8columns {
                do {
                    try run(stmt, [])
                } catch DatabaseError.stepFailed(let message)
                    where message.contains("duplicate column name") {
                    continue
                }
            }
        }
        if current < Self.schemaVersion {
            try run("PRAGMA user_version=\(Self.schemaVersion);", [])
        }
    }

    // MARK: - Internals (always called on queue)

    private func run(_ sql: String, _ args: [SQLiteValue]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, args)
        // PRAGMA statements (e.g. journal_mode) return a row instead of DONE.
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastError())
        }
    }

    private func fetch(_ sql: String, _ args: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, args)
        var rows: [[String: SQLiteValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: SQLiteValue] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0 ..< count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = .integer(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let ptr = sqlite3_column_text(stmt, i) {
                        let byteCount = Int(sqlite3_column_bytes(stmt, i))
                        let buffer = UnsafeBufferPointer(start: ptr, count: byteCount)
                        row[name] = .text(String(bytes: buffer, encoding: .utf8) ?? "")
                    } else {
                        row[name] = .null
                    }
                case SQLITE_BLOB:
                    // Security-scoped bookmarks (destination_bookmark) are
                    // raw bytes. Exposed as base64 text so SQLiteValue needs
                    // no new case; decoded at read time.
                    if let ptr = sqlite3_column_blob(stmt, i) {
                        let byteCount = Int(sqlite3_column_bytes(stmt, i))
                        let data = Data(bytes: ptr, count: byteCount)
                        row[name] = .text("blob:" + data.base64EncodedString())
                    } else {
                        row[name] = .null
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLiteValue]) throws {
        for (index, value) in args.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .integer(let v):
                sqlite3_bind_int64(stmt, i, Int64(v))
            case .real(let v):
                sqlite3_bind_double(stmt, i, v)
            case .text(let v):
                // "blob:<base64>" values bind as actual BLOBs so the column
                // type stays BLOB (see fetch mapping above).
                if let data = Self.blobPayload(v) {
                    // Lifetime: SQLITE_TRANSIENT so SQLite copies the bytes
                    // during bind, before the closure returns. (A standalone
                    // probe binary verified bind_blob round-trips
                    // byte-identical with this pattern.)
                    _ = data.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, i, ptr.baseAddress, Int32(data.count), Self.transient)
                    }
                } else {
                    // Lifetime (Workstream 6 fix): sqlite3_bind_text with a
                    // nil destructor (SQLITE_STATIC) borrows the pointer —
                    // but (v as NSString).utf8String is only valid for the
                    // life of the autoreleased NSString bridge, which may
                    // not survive past this call on all paths. Use
                    // SQLITE_TRANSIENT so SQLite copies the UTF-8 bytes
                    // immediately. Same cost class (short strings), no
                    // use-after-free window.
                    _ = v.withCString { ptr in
                        sqlite3_bind_text(stmt, i, ptr, -1, Self.transient)
                    }
                }
            case .null:
                sqlite3_bind_null(stmt, i)
            }
        }
    }

    /// SQLITE_TRANSIENT for bind bytes (copied by SQLite immediately).
    /// Correct for BOTH blob and text: the source buffer (Data bytes,
    /// withCString pointer) is only valid inside the bind call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Decode a "blob:<base64>" SQLiteValue payload. Nil for plain text.
    static func blobPayload(_ text: String) -> Data? {
        guard text.hasPrefix("blob:") else { return nil }
        return Data(base64Encoded: String(text.dropFirst(5)))
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

enum DatabaseError: Error {
    case openFailed
    case prepareFailed(String)
    case stepFailed(String)

    /// Structured failure detail for diagnostics (persist logs the real
    /// SQLite message; errorDescription stays user-safe).
    var sqliteMessage: String? {
        switch self {
        case .prepareFailed(let m), .stepFailed(let m): return m
        case .openFailed: return nil
        }
    }
}

/// Structured database startup failure. Thrown by Database.init paths and
/// DatabaseBoot helpers so AppContainer can route every failure to the
/// recovery UI instead of crashing. Cases are user-actionable categories,
/// not SQLite jargon (raw messages ride along in `detail` for logging).
enum DatabaseStartupError: Error, Equatable {
    /// sqlite3_open failed or the handle is unusable.
    case openFailed(detail: String)
    /// A schema/migration statement failed partway.
    case migrationFailed(fromVersion: Int, detail: String)
    /// PRAGMA integrity_check returned non-ok rows.
    case integrityFailed(detail: String)
    /// PRAGMA foreign_key_check returned orphan rows.
    case foreignKeyFailed(detail: String)
    /// Anything else (backup I/O, unexpected state). Never fatalError.
    case unrecoverable(detail: String)

    /// User-safe one-liner for the recovery UI. No SQLite jargon.
    var userMessage: String {
        switch self {
        case .openFailed:
            return "Kyoku couldn't open its library database file."
        case .migrationFailed:
            return "Kyoku couldn't update its library database to the current version."
        case .integrityFailed:
            return "Kyoku's library database didn't pass its health check."
        case .foreignKeyFailed:
            return "Kyoku's library database has broken links between records."
        case .unrecoverable:
            return "Kyoku ran into an unexpected problem with its library database."
        }
    }

    /// Raw diagnostic detail for logging only (never shown verbatim in UI).
    var logDetail: String {
        switch self {
        case .openFailed(let d), .migrationFailed(_, let d), .integrityFailed(let d),
             .foreignKeyFailed(let d), .unrecoverable(let d):
            return d
        }
    }
}

enum SQLiteValue {
    case integer(Int)
    case real(Double)
    case text(String)
    case null

    var integer: Int {
        if case .integer(let v) = self { return v }
        return 0
    }

    var text: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    var real: Double? {
        if case .real(let v) = self { return v }
        return nil
    }
}
