import Foundation
import SQLite3

/// Minimal SQLite wrapper. Serializes all access on one queue.
/// Migrations are versioned; extend `migrate()` for v2+.
final class Database {
    private let queue = DispatchQueue(label: "com.kyoku.app.database")
    private let path: String
    private let db: OpaquePointer

    static let schemaVersion = 1

    init(path: String? = nil) throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Kyoku", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = path ?? base.appendingPathComponent("kyoku.sqlite").path
        self.path = resolved

        var handle: OpaquePointer?
        guard sqlite3_open(resolved, &handle) == SQLITE_OK, let opened = handle else {
            throw DatabaseError.openFailed
        }
        self.db = opened
        try migrate()
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

    private func migrate() throws {
        try run("PRAGMA journal_mode=WAL;", [])
        try run("PRAGMA foreign_keys=ON;", [])
        let current = (try fetch("PRAGMA user_version;", []).first?.values.first).map { $0.integer } ?? 0
        if current < Self.schemaVersion {
            for stmt in Schema.v1 { try run(stmt, []) }
            try run("PRAGMA user_version=1;", [])
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
                sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, nil)
            case .null:
                sqlite3_bind_null(stmt, i)
            }
        }
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

enum DatabaseError: Error {
    case openFailed
    case prepareFailed(String)
    case stepFailed(String)
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
