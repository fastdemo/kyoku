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
                "SELECT id, source_id, name, destination, destination_bookmark, profile_id, schedule, removal_policy, enabled, last_run_at, last_success_at, last_error, consecutive_failures, created_at, updated_at FROM sync_jobs ORDER BY created_at;"
            ).compactMap(Self.make)
        } catch {
            logger.error("SyncJobs load failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func create(sourceID: String, name: String, destination: String,
                destinationBookmark: Data? = nil,
                profileID: String = DownloadProfile.appleLibrary.id,
                schedule: SyncSchedule = .manual,
                removalPolicy: RemovalPolicy = .ask) -> SyncJobConfig {
        let job = SyncJobConfig(sourceID: sourceID, name: name, destination: destination,
                                destinationBookmark: destinationBookmark,
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

    /// Resolve a usable destination URL for a job: the job's own
    /// bookmark when valid, else the path string, else the music root.
    /// Returns nil + records the failure mode when nothing is usable.
    /// Never deletes configuration; callers surface attention from it.
    enum DestinationStatus: Equatable, Sendable {
        case ok(URL)
        case missingOnDisk(String)
        case accessDenied(String)
        case noDestination
    }

    func resolveDestination(for job: SyncJobConfig,
                            musicRoot: URL?) -> DestinationStatus {
        // Custom destination with its own bookmark.
        // NOTE: in the test host (and any non-sandboxed context)
        // startAccessingSecurityScopedResource() returns false for
        // non-scoped bookmarks — that must NOT read as accessDenied.
        // Only bookmarks created WITH .withSecurityScope require scoped
        // access; plain bookmarks resolve + validate by filesystem only.
        if !job.destination.isEmpty {
            if let data = job.destinationBookmark,
               let (url, scoped) = Self.resolveBookmark(data) {
                if Self.isUsableDirectory(url) {
                    // Plain (non-scoped) bookmarks — tests and
                    // non-sandboxed contexts — validate by filesystem only.
                    // Scoped bookmarks (production) must start access.
                    if !scoped { return .ok(url) }
                    if url.startAccessingSecurityScopedResource() {
                        // Balanced by the caller after use; here we just
                        // verify access starts. Stop immediately — actual
                        // scoped access happens per-operation in the queue.
                        url.stopAccessingSecurityScopedResource()
                        return .ok(url)
                    }
                    return .accessDenied(job.destination)
                }
                return .missingOnDisk(job.destination)
            }
            // No (or unresolvable) bookmark: path may still be inside the
            // music subtree, which MusicFolderAccess already covers.
            if let root = musicRoot,
               job.destination.hasPrefix(root.path),
               Self.isUsableDirectory(URL(fileURLWithPath: job.destination)) {
                return .ok(URL(fileURLWithPath: job.destination))
            }
            // Outside the managed subtree without a valid bookmark.
            if Self.isUsableDirectory(URL(fileURLWithPath: job.destination)) {
                return .accessDenied(job.destination)
            }
            return .missingOnDisk(job.destination)
        }
        guard let root = musicRoot else { return .noDestination }
        return .ok(root)
    }

    /// Validate all jobs' destinations at launch. Returns job IDs needing
    /// attention (missing/inaccessible), with attention items created.
    /// Configuration is preserved; nothing is deleted or rewritten.
    func validateAll(records: AutomationRecordStore, musicRoot: URL?) -> [String] {
        var needingAttention: [String] = []
        for job in jobs {
            switch resolveDestination(for: job, musicRoot: musicRoot) {
            case .ok:
                continue
            case .missingOnDisk(let path), .accessDenied(let path):
                needingAttention.append(job.id)
                let kind = "destinationInaccessible"
                let exists = records.openAttention.contains {
                    $0.kind == kind && $0.syncJobID == job.id
                }
                if !exists {
                    records.addAttention(AttentionItem(
                        kind: kind,
                        title: "Sync destination needs attention: \(job.name)",
                        detail: "\(path) is not accessible. Choose the folder again in the job editor.",
                        syncJobID: job.id))
                }
            case .noDestination:
                continue // music root checked separately via FolderStatus
            }
        }
        return needingAttention
    }

    /// Resolve bookmark bytes → (URL, scoped). `scoped` is true only
    /// when the bookmark requires security-scoped access (production
    /// bookmarks created with .withSecurityScope). Detection: resolve
    /// WITHOUT options first — this succeeds for both kinds. Then resolve
    /// WITH .withSecurityScope: a scoped-only bookmark fails plain
    /// resolution but succeeds scoped. If both succeed, treat as plain
    /// (filesystem validation governs; scoped access is additionally
    /// attempted by callers and must succeed when truly required).
    private static func resolveBookmark(_ data: Data) -> (URL, Bool)? {
        var plainURL: URL?
        do {
            var stale = false
            plainURL = try URL(resolvingBookmarkData: data, options: [],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            plainURL = nil
        }
        // Scoped-only data (plain fails) → scoped.
        if plainURL == nil {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                return (url, true)
            } catch {
                return nil
            }
        }
        return (plainURL!, false)
    }

    private static func isUsableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    // MARK: - Private

    private static func make(_ row: [String: SQLiteValue]) -> SyncJobConfig? {
        guard let id = row["id"]?.text, let sourceID = row["source_id"]?.text else { return nil }
        func date(_ key: String) -> Date? {
            row[key]?.real.map(Date.init(timeIntervalSince1970:))
        }
        // destination_bookmark arrives as "blob:<base64>" text (see
        // Database BLOB mapping); decode back to raw bookmark bytes.
        let bookmark: Data? = row["destination_bookmark"]?.text.flatMap(Database.blobPayload)
        return SyncJobConfig(
            id: id,
            sourceID: sourceID,
            name: row["name"]?.text ?? "",
            destination: row["destination"]?.text ?? "",
            destinationBookmark: bookmark,
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
                INSERT INTO sync_jobs (id, source_id, name, destination, destination_bookmark, profile_id, schedule, removal_policy, enabled, last_run_at, last_success_at, last_error, consecutive_failures, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id=excluded.source_id, name=excluded.name, destination=excluded.destination,
                    destination_bookmark=excluded.destination_bookmark,
                    profile_id=excluded.profile_id, schedule=excluded.schedule,
                    removal_policy=excluded.removal_policy, enabled=excluded.enabled,
                    last_run_at=excluded.last_run_at, last_success_at=excluded.last_success_at,
                    last_error=excluded.last_error, consecutive_failures=excluded.consecutive_failures,
                    updated_at=excluded.updated_at;
                """,
                [.text(job.id), .text(job.sourceID), .text(job.name), .text(job.destination),
                 job.destinationBookmark.map { .text("blob:" + $0.base64EncodedString()) } ?? .null,
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
            // Log the structured SQLite message (not just the opaque enum
            // description) so BLOB/binding failures are diagnosable.
            if let dbError = error as? DatabaseError,
               let detail = dbError.sqliteMessage {
                logger.error("SyncJob persist failed: \(detail)")
            } else {
                logger.error("SyncJob persist failed: \(error.localizedDescription)")
            }
        }
    }
}
