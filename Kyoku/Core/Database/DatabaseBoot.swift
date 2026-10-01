import Foundation
import SQLite3

/// Workstream 6: safe database backup + reset + boot orchestration.
///
/// Responsibilities (and ONLY these):
/// - Timestamped backups that never collide and never destroy data.
/// - Fresh-database reset that preserves the old file as a backup first.
/// - One structured boot() entry point: open → (migrate happens inside
///   Database.init) → verify, mapped to DatabaseStartupError.
///
/// What this type does NOT do:
/// - No silent auto-restore (a failed migration keeps its backup; the user
///   chooses retry vs reset in the recovery UI).
/// - No deletion of the live DB except via rename-to-backup (reset path).
/// - No SQLite jargon in user-facing strings (see DatabaseStartupError).
enum DatabaseBoot {
    /// Backup file naming: kyoku.sqlite.<reason>-YYYYMMDD-HHMMSS[ Huey P Newton…].
    /// Example: kyoku.sqlite.corrupt-20260101-120000
    /// Example: kyoku.sqlite.corrupt-20260101-120000-1 (collision suffix)
    ///
    /// Non-colliding: when the name exists, appends -1, -2, … rather than
    /// overwriting an earlier backup.
    static func backupName(reason: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let clean = reason
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let collapsed = String(String(clean).prefix(48))
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let tag = collapsed.isEmpty ? "backup" : collapsed
        return "kyoku.sqlite.\(tag)-\(stamp)"
    }

    /// Copy a database file to a timestamped backup next to it.
    /// Uses the SQLite backup API (consistent snapshot incl. WAL frames)
    /// rather than a raw file copy, which could catch a checkpoint halfway.
    /// Skips -wal/-shm sidecars: the backup API folds them in; copying them
    /// separately would risk a mismatched trio on restore.
    /// Returns the backup file URL. Never overwrites an existing backup.
    @discardableResult
    static func backupDatabase(at dbPath: String, reason: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else {
            throw DatabaseStartupError.unrecoverable(
                detail: "nothing to back up at \(dbPath)")
        }
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let base = backupName(reason: reason)
        var dest = dir.appendingPathComponent(base)
        var suffix = 0
        while fm.fileExists(atPath: dest.path) {
            suffix += 1
            dest = dir.appendingPathComponent("\(base)-\(suffix)")
        }
        try sqliteBackup(from: dbPath, to: dest.path)
        return dest
    }

    /// Low-level SQLite online-backup copy. Throws DatabaseStartupError on
    /// any failure (open/lock/step). Public so tests can verify the copy is
    /// complete (reopen + integrity_check) without going through Database.
    static func sqliteBackup(from sourcePath: String, to destPath: String) throws {
        var src: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let srcDB = src else {
            if let s = src { sqlite3_close(s) }
            throw DatabaseStartupError.unrecoverable(
                detail: "backup: cannot open source at \(sourcePath)")
        }
        defer { sqlite3_close(srcDB) }
        var dst: OpaquePointer?
        guard sqlite3_open(destPath, &dst) == SQLITE_OK, let dstDB = dst else {
            if let d = dst { sqlite3_close(d) }
            throw DatabaseStartupError.unrecoverable(
                detail: "backup: cannot create destination at \(destPath)")
        }
        defer { sqlite3_close(dstDB) }
        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
            throw DatabaseStartupError.unrecoverable(
                detail: "backup: init failed: \(String(cString: sqlite3_errmsg(dstDB)))")
        }
        defer { sqlite3_backup_finish(backup) }
        // -1 pages = entire DB in one step; busy/locked retries a few times
        // (source may have a lingering WAL writer), then give up loudly
        // rather than shipping a partial backup.
        var code: Int32 = 0
        for _ in 0 ..< 5 {
            code = sqlite3_backup_step(backup, -1)
            if code == SQLITE_DONE { break }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                sqlite3_sleep(50)
                continue
            }
            break
        }
        guard code == SQLITE_DONE else {
            try? FileManager.default.removeItem(atPath: destPath)
            throw DatabaseStartupError.unrecoverable(
                detail: "backup: step failed (code \(code)): \(String(cString: sqlite3_errmsg(dstDB)))")
        }
    }

    /// Structured boot outcome. `.ready` carries an open, migrated,
    /// verified Database. `.recovery` carries the classified error plus the
    /// live path so the UI can offer Retry (re-run boot) and Reset
    /// (resetDatabase, which backs up first).
    enum BootResult {
        case ready(Database)
        case recovery(error: DatabaseStartupError, dbPath: String)
    }

    /// Open → migrate → verify, mapping every failure to BootResult.recovery.
    /// The healthy path is unchanged (same Database.init). Never throws,
    /// never fatalErrors: a corrupt DB must land in recovery UI, not crash.
    static func boot(path: String? = nil) -> BootResult {
        let resolved: String
        if let path {
            resolved = path
        } else {
            do {
                resolved = try Database.defaultPath()
            } catch {
                return .recovery(
                    error: .openFailed(detail: "\(error)"),
                    dbPath: "(unknown)")
            }
        }
        do {
            let db = try Database(path: resolved)
            return .ready(db)
        } catch let startup as DatabaseStartupError {
            return .recovery(error: startup, dbPath: resolved)
        } catch {
            return .recovery(error: .unrecoverable(detail: "\(error)"), dbPath: resolved)
        }
    }

    /// Destructive recovery, made safe:
    /// 1. Rename the broken DB (+ -wal/-shm sidecars) to a timestamped
    ///    backup — never delete user data.
    /// 2. Create a fresh database via the normal init path (full schema).
    /// 3. Verify the fresh DB before returning it.
    ///
    /// If ANY step fails: the original file/backup is preserved and a
    /// structured error is thrown (caller shows it; no half-initialized DB
    /// ever reaches the app). Sidecar handling: -wal/-shm move WITH the
    /// main file so the backup trio stays consistent; stale sidecars never
    /// shadow the fresh file.
    static func resetDatabase(at dbPath: String) throws -> (fresh: Database, backupURL: URL) {
        let fm = FileManager.default
        let hadLiveFile = fm.fileExists(atPath: dbPath)
        // Step 1: preserve. Move (not copy) so the live path is free for a
        // genuinely fresh file — but a move is itself fallible (permissions),
        // hence the guard below, not a silent continue.
        let backupURL: URL
        if hadLiveFile {
            backupURL = try backupMove(at: dbPath, reason: "corrupt")
            // Sidecar debris check AFTER the move: the move above already
            // carried -wal/-shm alongside. Anything still at the live path
            // with these suffixes arrived between the moves (or is a stale
            // -journal): fold next to the backup, never leave shadowing.
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = dbPath + suffix
                if fm.fileExists(atPath: sidecar) {
                    let dest = backupURL.path + suffix
                    if !fm.fileExists(atPath: dest) {
                        try? fm.moveItem(atPath: sidecar, toPath: dest)
                    } else {
                        try? fm.removeItem(atPath: sidecar)
                    }
                }
            }
        } else {
            // No live file (e.g. openFailed on first run): still create a
            // marker backup name for UI consistency? No — nothing to
            // preserve. Fresh-create directly; backupURL points at the (empty)
            // slot for the caller's message. Document, don't invent data.
            let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            backupURL = dir.appendingPathComponent(backupName(reason: "corrupt"))
        }
        // Steps 2+3: fresh create + verify. Any throw propagates with the
        // backup intact (live path may hold a partial file — remove it so
        // the next retry starts clean, the BACKUP is the preserved copy).
        do {
            let fresh = try Database(path: dbPath)
            try fresh.verify()
            return (fresh, backupURL)
        } catch {
            try? fm.removeItem(atPath: dbPath)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? fm.removeItem(atPath: dbPath + suffix)
            }
            if let startup = error as? DatabaseStartupError {
                throw startup
            }
            throw DatabaseStartupError.unrecoverable(detail: "reset failed: \(error)")
        }
    }

    /// Rename the live trio (main + -wal/-shm) to backup names. The main
    /// file gets the canonical backup name; sidecars append their suffix.
    /// Never overwrites: collision suffixes apply per file.
    private static func backupMove(at dbPath: String, reason: String) throws -> URL {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let base = backupName(reason: reason)
        var dest = dir.appendingPathComponent(base)
        var suffix = 0
        while fm.fileExists(atPath: dest.path) {
            suffix += 1
            dest = dir.appendingPathComponent("\(base)-\(suffix)")
        }
        do {
            try fm.moveItem(atPath: dbPath, toPath: dest.path)
        } catch {
            throw DatabaseStartupError.unrecoverable(
                detail: "reset: cannot preserve existing database: \(error)")
        }
        for sidecarSuffix in ["-wal", "-shm", "-journal"] {
            let sidecar = dbPath + sidecarSuffix
            if fm.fileExists(atPath: sidecar) {
                // Best-effort: sidecar loss never fails the reset (WAL frames
                // without their main file are not independently restorable).
                try? fm.moveItem(atPath: sidecar, toPath: dest.path + sidecarSuffix)
            }
        }
        return dest
    }
}
