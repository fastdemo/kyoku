import Combine
import Foundation

/// Persistent SyncJob store: CRUD + run bookkeeping + retry counters.
/// Scheduling decisions live in SyncScheduler2; execution in SyncEngine.
@MainActor
final class SyncJobStore: ObservableObject {
    @Published private(set) var jobs: [SyncJobConfig] = []

    private let database: Database
    private let logger = KyokuLogger(subsystem: "core", category: "syncjobs")

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
        do {
            jobs = try database.query(
                "SELECT id, source_id, name, destination, profile_id, schedule, removal_policy, enabled, last_run_at, last_success_at, last_error, consecutive_failures, created_at, updated_at FROM sync_jobs ORDER BY created_at;"
            ).compactMap(Self.make)
        } catch {
            logger.error("SyncJobs load failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func create(sourceID: String, name: String, destination: String,
                profileID: String = DownloadProfile.appleLibrary.id,
                schedule: SyncSchedule = .manual,
                removalPolicy: RemovalPolicy = .ask) -> SyncJobConfig {
        let job = SyncJobConfig(sourceID: sourceID, name: name, destination: destination,
                                profileID: profileID, schedule: schedule,
                                removalPolicy: removalPolicy)
        persist(job)
        refresh()
        return job
    }

    func update(_ job: SyncJobConfig) {
        var j = job
        j.updatedAt = Date()
        persist(j)
        refresh()
    }

    func remove(id: String) {
        do {
            try database.execute("DELETE FROM sync_jobs WHERE id=?;", [.text(id)])
        } catch {
            logger.error("SyncJob remove failed: \(error.localizedDescription)")
            return
        }
        refresh()
    }

    func setEnabled(id: String, enabled: Bool) {
        guard var j = jobs.first(where: { $0.id == id }) else { return }
        j.enabled = enabled
        update(j)
    }

    /// Record a finished run outcome for backoff + status display.
    func recordRunOutcome(id: String, success: Bool, error: String? = nil) {
        guard var j = jobs.first(where: { $0.id == id }) else { return }
        let now = Date()
        j.lastRunAt = now
        if success {
            j.lastSuccessAt = now
            j.lastError = nil
            j.consecutiveFailures = 0
        } else {
            j.lastError = error
            j.consecutiveFailures += 1
        }
        update(j)
    }

    // MARK: - Private

    private static func make(_ row: [String: SQLiteValue]) -> SyncJobConfig? {
        guard let id = row["id"]?.text, let sourceID = row["source_id"]?.text else { return nil }
        func date(_ key: String) -> Date? {
            row[key]?.real.map(Date.init(timeIntervalSince1970:))
        }
        return SyncJobConfig(
            id: id,
            sourceID: sourceID,
            name: row["name"]?.text ?? "",
            destination: row["destination"]?.text ?? "",
            profileID: row["profile_id"]?.text ?? DownloadProfile.appleLibrary.id,
            schedule: SyncSchedule(rawValue: row["schedule"]?.text ?? "manual") ?? .manual,
            removalPolicy: RemovalPolicy(rawValue: row["removal_policy"]?.text ?? "ask") ?? .ask,
            enabled: (row["enabled"]?.integer ?? 1) != 0,
            lastRunAt: date("last_run_at"),
            lastSuccessAt: date("last_success_at"),
            lastError: row["last_error"]?.text,
            consecutiveFailures: row["consecutive_failures"]?.integer ?? 0,
            createdAt: date("created_at") ?? Date(),
            updatedAt: date("updated_at") ?? Date()
        )
    }

    private func persist(_ job: SyncJobConfig) {
        do {
            try database.execute(
                """
                INSERT INTO sync_jobs (id, source_id, name, destination, profile_id, schedule, removal_policy, enabled, last_run_at, last_success_at, last_error, consecutive_failures, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id=excluded.source_id, name=excluded.name, destination=excluded.destination,
                    profile_id=excluded.profile_id, schedule=excluded.schedule,
                    removal_policy=excluded.removal_policy, enabled=excluded.enabled,
                    last_run_at=excluded.last_run_at, last_success_at=excluded.last_success_at,
                    last_error=excluded.last_error, consecutive_failures=excluded.consecutive_failures,
                    updated_at=excluded.updated_at;
                """,
                [.text(job.id), .text(job.sourceID), .text(job.name), .text(job.destination),
                 .text(job.profileID), .text(job.schedule.rawValue), .text(job.removalPolicy.rawValue),
                 .integer(job.enabled ? 1 : 0),
                 job.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                 job.lastSuccessAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                 job.lastError.map(SQLiteValue.text) ?? .null,
                 .integer(job.consecutiveFailures),
                 .real(job.createdAt.timeIntervalSince1970),
                 .real(job.updatedAt.timeIntervalSince1970)]
            )
        } catch {
            logger.error("SyncJob persist failed: \(error.localizedDescription)")
        }
    }
}
