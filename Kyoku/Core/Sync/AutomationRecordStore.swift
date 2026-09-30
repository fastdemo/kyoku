import Combine
import Foundation

/// Persistent automation records: sync runs, attention inbox, activity feed.
/// Thin SQLite wrapper; SyncEngine writes, views read.
@MainActor
final class AutomationRecordStore: ObservableObject {
    @Published private(set) var runs: [SyncRun] = []
    @Published private(set) var openAttention: [AttentionItem] = []
    @Published private(set) var recentActivity: [ActivityEvent] = []

    private let database: Database
    private let logger = KyokuLogger(subsystem: "core", category: "automation")

    /// Nonisolated init (cf. DownloadQueue): actor-bound load
    /// happens via refresh() called on the main thread after init.
    nonisolated init(database: Database) {
        self.database = database
    }

    /// Actor-bound startup: load persisted rows. Called once from the
    /// main thread after construction (cf. DownloadQueue.start()).
    func start() {
        refresh()
    }

    func refresh() {
        runs = loadRuns(limit: 50)
        openAttention = loadAttention()
        recentActivity = loadActivity(limit: 100)
    }

    // MARK: - Sync runs

    @discardableResult
    func beginRun(syncJobID: String) -> SyncRun {
        let run = SyncRun(syncJobID: syncJobID)
        do {
            try database.execute(
                "INSERT INTO sync_runs (id, sync_job_id, started_at, status) VALUES (?, ?, ?, 'running');",
                [.text(run.id), .text(run.syncJobID), .real(run.startedAt.timeIntervalSince1970)]
            )
        } catch {
            logger.error("beginRun failed: \(error.localizedDescription)")
        }
        refresh()
        return run
    }

    func finishRun(_ run: SyncRun) {
        do {
            try database.execute(
                """
                UPDATE sync_runs SET finished_at=?, status=?, added_count=?, removed_count=?,
                    changed_count=?, unchanged_count=?, queued_count=?, downloaded_count=?,
                    failed_count=?, error=? WHERE id=?;
                """,
                [run.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                 .text(run.status.rawValue),
                 .integer(run.addedCount), .integer(run.removedCount),
                 .integer(run.changedCount), .integer(run.unchangedCount),
                 .integer(run.queuedCount), .integer(run.downloadedCount),
                 .integer(run.failedCount),
                 run.error.map(SQLiteValue.text) ?? .null,
                 .text(run.id)]
            )
        } catch {
            logger.error("finishRun failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Runs stuck in 'running' at launch (crash/kill mid-sync). Callers
    /// requeue or fail them explicitly; this just lists them.
    func interruptedRuns() -> [SyncRun] {
        loadRuns(status: "running", limit: 100)
    }

    func runsForJob(_ jobID: String, limit: Int = 20) -> [SyncRun] {
        do {
            return try database.query(
                "SELECT * FROM sync_runs WHERE sync_job_id=? ORDER BY started_at DESC LIMIT ?;",
                [.text(jobID), .integer(limit)]
            ).compactMap(Self.makeRun)
        } catch {
            logger.error("runsForJob failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Attention inbox

    @discardableResult
    func addAttention(_ item: AttentionItem) -> AttentionItem {
        do {
            try database.execute(
                """
                INSERT INTO attention_items (id, kind, title, detail, sync_job_id, source_url, track_url, task_id, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [.text(item.id), .text(item.kind), .text(item.title), .text(item.detail),
                 item.syncJobID.map(SQLiteValue.text) ?? .null,
                 item.sourceURL.map(SQLiteValue.text) ?? .null,
                 item.trackURL.map(SQLiteValue.text) ?? .null,
                 item.taskID.map(SQLiteValue.text) ?? .null,
                 .text(item.isOpen ? "open" : "resolved"),
                 .real(item.createdAt.timeIntervalSince1970),
                 .real(item.updatedAt.timeIntervalSince1970)]
            )
        } catch {
            logger.error("addAttention failed: \(error.localizedDescription)")
        }
        refresh()
        return item
    }

    func resolveAttention(id: String) {
        do {
            try database.execute(
                "UPDATE attention_items SET status='resolved', updated_at=? WHERE id=?;",
                [.real(Date().timeIntervalSince1970), .text(id)]
            )
        } catch {
            logger.error("resolveAttention failed: \(error.localizedDescription)")
            return
        }
        refresh()
    }

    /// Dedupe helper: open item for the same track URL + kind, if any.
    func openItemForTrack(kind: String, trackURL: String) -> AttentionItem? {
        openAttention.first { $0.kind == kind && $0.trackURL == trackURL }
    }

    // MARK: - Activity feed

    func logActivity(syncJobID: String?, kind: String, title: String, detail: String = "") {
        do {
            try database.execute(
                "INSERT INTO activity_events (sync_job_id, kind, title, detail, created_at) VALUES (?, ?, ?, ?, ?);",
                [syncJobID.map(SQLiteValue.text) ?? .null, .text(kind), .text(title),
                 .text(detail), .real(Date().timeIntervalSince1970)]
            )
        } catch {
            logger.error("logActivity failed: \(error.localizedDescription)")
            return
        }
        refresh()
    }

    // MARK: - Private

    private func loadRuns(status: String? = nil, limit: Int) -> [SyncRun] {
        do {
            if let status {
                return try database.query(
                    "SELECT * FROM sync_runs WHERE status=? ORDER BY started_at DESC LIMIT ?;",
                    [.text(status), .integer(limit)]
                ).compactMap(Self.makeRun)
            }
            return try database.query(
                "SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT ?;",
                [.integer(limit)]
            ).compactMap(Self.makeRun)
        } catch {
            logger.error("loadRuns failed: \(error.localizedDescription)")
            return []
        }
    }

    private func loadAttention() -> [AttentionItem] {
        do {
            return try database.query(
                "SELECT * FROM attention_items WHERE status='open' ORDER BY created_at DESC LIMIT 200;"
            ).compactMap(Self.makeAttention)
        } catch {
            logger.error("loadAttention failed: \(error.localizedDescription)")
            return []
        }
    }

    private func loadActivity(limit: Int) -> [ActivityEvent] {
        do {
            return try database.query(
                "SELECT id, sync_job_id, kind, title, detail, created_at FROM activity_events ORDER BY created_at DESC LIMIT ?;",
                [.integer(limit)]
            ).compactMap { row in
                guard let id = row["id"]?.integer else { return nil }
                return ActivityEvent(
                    id: id,
                    syncJobID: row["sync_job_id"]?.text,
                    kind: row["kind"]?.text ?? "",
                    title: row["title"]?.text ?? "",
                    detail: row["detail"]?.text ?? "",
                    createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
                )
            }
        } catch {
            logger.error("loadActivity failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func makeRun(_ row: [String: SQLiteValue]) -> SyncRun? {
        guard let id = row["id"]?.text, let jobID = row["sync_job_id"]?.text else { return nil }
        var run = SyncRun(
            id: id, syncJobID: jobID,
            startedAt: row["started_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date())
        run.finishedAt = row["finished_at"]?.real.map(Date.init(timeIntervalSince1970:))
        run.status = SyncRun.Status(rawValue: row["status"]?.text ?? "running") ?? .running
        run.addedCount = row["added_count"]?.integer ?? 0
        run.removedCount = row["removed_count"]?.integer ?? 0
        run.changedCount = row["changed_count"]?.integer ?? 0
        run.unchangedCount = row["unchanged_count"]?.integer ?? 0
        run.queuedCount = row["queued_count"]?.integer ?? 0
        run.downloadedCount = row["downloaded_count"]?.integer ?? 0
        run.failedCount = row["failed_count"]?.integer ?? 0
        run.error = row["error"]?.text
        return run
    }

    private static func makeAttention(_ row: [String: SQLiteValue]) -> AttentionItem? {
        guard let id = row["id"]?.text else { return nil }
        func date(_ key: String) -> Date {
            row[key]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
        }
        return AttentionItem(
            id: id,
            kind: row["kind"]?.text ?? "",
            title: row["title"]?.text ?? "",
            detail: row["detail"]?.text ?? "",
            syncJobID: row["sync_job_id"]?.text,
            sourceURL: row["source_url"]?.text,
            trackURL: row["track_url"]?.text,
            taskID: row["task_id"]?.text,
            isOpen: (row["status"]?.text ?? "open") == "open",
            createdAt: date("created_at"),
            updatedAt: date("updated_at")
        )
    }
}
