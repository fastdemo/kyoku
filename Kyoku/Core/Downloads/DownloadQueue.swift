import Combine
import Foundation

/// Persistent, observable download queue. Owns task state, drives the
/// engine serially (one download at a time), and persists every
/// transition so restarts don't destroy the queue.
///
/// Threading: @MainActor for SwiftUI publishing. Engine calls are
/// `await`ed off the actor; state mutations hop back via the actor.
/// Restart recovery: tasks stuck in `.resolving`/`.downloading`/
/// `.processing` at launch are reset to `.pending` (their subprocess
/// died with the previous launch).
@MainActor
final class DownloadQueue: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var activeTaskID: String?
    @Published private(set) var activeProgress: DownloadProgress?

    private let database: Database
    private let engine: any DownloadEngine
    private let library: LibraryStore
    private let musicFolderAccess: MusicFolderAccess
    /// Resolves the download destination for a task: the owning sync job's
    /// playlist folder when set, else the music root. Injected (not read
    /// from SyncJobStore directly) so the queue never depends on
    /// SyncJobStore (avoids a Core↔Core dependency). Nil = music root.
    private let destinationForJob: (String?) -> URL?
    /// Resolves the playlist linked to a sync job (Add Playlist workflow),
    /// so completed downloads attach to it. Injected for the same
    /// dependency reason. Nil = no playlist link (manual/one-off).
    private let playlistIDForJob: ((String?) -> String?)?
    /// Starts security-scoped access for a job's custom destination
    /// (outside the music subtree) and returns a stop closure. Injected
    /// for the same dependency reason. Nil = no extra access needed
    /// (music root is covered by MusicFolderAccess's held access).
    private let scopeForJob: ((String?) -> (() -> Void)?)?
    /// Resolves the default profile for one-off downloads. Sync jobs carry
    /// their own profileID; this is only the fallback. Injected (not read
    /// from AppSettings directly) so tests control it without UserDefaults.
    private let defaultProfile: () -> DownloadProfile
    /// Resolves a sync job's profile by ID. Injected so the queue never
    /// depends on SyncJobStore directly (avoids a Core↔Core dependency).
    /// Nil profileID (one-off downloads) falls back to defaultProfile().
    private let profileForJob: (String?) -> DownloadProfile
    private let logger = KyokuLogger(subsystem: "core", category: "queue")

    private var worker: Task<Void, Never>?
    /// Parked wake-up continuations for the idle worker loop. kick()
    /// resumes them; the timeout task in waitForKick does the same after
    /// 5s. Cooperative only — never Task.cancel.
    private var kickContinuations: [CheckedContinuation<Void, Never>] = []
    /// Set while the active task's cancel was user-requested. Distinguishes
    /// intentional cancellation (→ .cancelled) from backend crashes that
    /// surface as non-zero exits (→ .failed + auto-retry).
    private var activeCancelRequested = false
    /// Parked continuations for tasks awaiting user cancel, keyed by task
    /// ID. cancel() resumes the matching one so run()'s cancel branch wins
    /// the race even when the backend stream never yields again.
    private var cancelWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    /// DownloadQueue is @MainActor but constructed from AppContainer's
    /// nonisolated init: keep init nonisolated and do the actor-bound work
    /// (DB recovery + load + worker start) on first use instead.
    nonisolated init(
        database: Database,
        engine: any DownloadEngine,
        library: LibraryStore,
        musicFolderAccess: MusicFolderAccess,
        defaultProfile: @escaping () -> DownloadProfile = { .appleLibrary },
        profileForJob: @escaping (String?) -> DownloadProfile? = { _ in nil },
        destinationForJob: @escaping (String?) -> URL? = { _ in nil },
        playlistIDForJob: ((String?) -> String?)? = nil,
        scopeForJob: ((String?) -> (() -> Void)?)? = nil
    ) {
        self.database = database
        self.engine = engine
        self.library = library
        self.musicFolderAccess = musicFolderAccess
        self.destinationForJob = destinationForJob
        self.playlistIDForJob = playlistIDForJob
        self.scopeForJob = scopeForJob
        self.defaultProfile = defaultProfile
        // NOTE: fallback() is evaluated per-task at run() time (not here),
        // so changing the global default affects only tasks enqueued
        // afterwards. profileForJob(nil) → nil → defaultProfile().
        let fallback = defaultProfile
        let resolve = profileForJob
        self.profileForJob = { resolve($0) ?? fallback() }
    }

    /// Must be called once from the main thread after construction.
    /// (Split from init because AppContainer.init is nonisolated.)
    /// Safe to call multiple times (tests create several queues over one
    /// DB): only starts the worker loop when none is alive.
    func start() {
        recoverInterruptedTasks()
        load()
        startWorker()
    }

    // MARK: - Public API

    /// Enqueue resolved songs for download. Source-URL uniqueness is
    /// enforced by the DB partial unique index: re-enqueue of the same URL
    /// refreshes the existing row (resets to pending for a fresh attempt)
    /// instead of creating a second active task. Sync callers pass
    /// job/run/source IDs for linkage (one-off UI downloads leave nil).
    func enqueue(_ songs: [ResolvedSong], sourceURL: String,
                 syncJobID: String? = nil, syncRunID: String? = nil,
                 sourceID: String? = nil, profileID: String? = nil) {
        var added = 0
        var refreshed = 0
        for song in songs {
            let now = Date()
            if let index = tasks.firstIndex(where: { $0.sourceURL == song.url }) {
                // Already tracked: refresh metadata + linkage, requeue only
                // when settled (never disturb an active download).
                tasks[index].resolvedSong = song
                tasks[index].updatedAt = now
                if tasks[index].syncJobID == nil { tasks[index].syncJobID = syncJobID }
                if tasks[index].syncRunID == nil { tasks[index].syncRunID = syncRunID }
                if tasks[index].sourceID == nil { tasks[index].sourceID = sourceID }
                // Adopt the job's profile when the task has none yet (e.g.
                // a one-off created before the job existed). Never overwrite
                // an already-assigned profile: in-flight/retried tasks keep
                // the profile they started with.
                if tasks[index].profileID == nil { tasks[index].profileID = profileID }
                switch tasks[index].state {
                case .done:
                    persist(tasks[index])
                    refreshed += 1
                case .failed, .cancelled:
                    tasks[index].state = .pending
                    tasks[index].attempts = 0
                    tasks[index].nextRetryAt = nil
                    tasks[index].lastError = nil
                    persist(tasks[index])
                    refreshed += 1
                case .pending, .resolving, .downloading, .processing:
                    persist(tasks[index])
                }
                continue
            }
            let task = DownloadTask(
                sourceURL: song.url,
                state: .pending,
                createdAt: now,
                updatedAt: now,
                resolvedSong: song,
                syncJobID: syncJobID,
                syncRunID: syncRunID,
                sourceID: sourceID,
                profileID: profileID
            )
            persist(task)
            tasks.append(task)
            added += 1
        }
        logger.info("Enqueued \(added) tasks from \(sourceURL) (\(refreshed) refreshed, \(songs.count - added - refreshed) already active).")
        kick()
    }

    /// Cancel a pending task, or stop the active download.
    /// Active cancellation terminates the real spotdl subprocess via the
    /// engine (registration ID), not just the Swift consumer task — so no
    /// orphaned backend keeps downloading after the UI says cancelled.
    func cancel(taskID: String) {
        if activeTaskID == taskID {
            activeCancelRequested = true
            // Wake run()'s cancel branch (wins the race even if the
            // backend stream never yields again), then kill the subprocess.
            if let waiter = cancelWaiters.removeValue(forKey: taskID) {
                waiter.resume()
            }
            Task { await engine.cancel(taskID: taskID) }
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .cancelled
        tasks[index].updatedAt = Date()
        persist(tasks[index])
    }

    /// Tombstone finished/failed/cancelled tasks: removed from the visible
    /// queue AND marked cleared_at in SQLite, so restart recovery can
    /// never resurrect them. History remains queryable in the DB.
    func clearFinished() {
        let ids = tasks
            .filter { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
            .map(\.id)
        tasks.removeAll { ids.contains($0.id) }
        guard !ids.isEmpty else { return }
        do {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try database.execute(
                "UPDATE download_tasks SET cleared_at=?, updated_at=? WHERE id IN (\(placeholders));",
                [.real(Date().timeIntervalSince1970),
                 .real(Date().timeIntervalSince1970)] + ids.map(SQLiteValue.text)
            )
        } catch {
            logger.error("clearFinished persist failed: \(error.localizedDescription)")
        }
    }

    /// Manual retry: reset attempts/backoff and requeue immediately.
    /// Auto-retry (markFailed path) keeps the attempt count and backs off.
    func retry(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .pending
        tasks[index].lastError = nil
        tasks[index].attempts = 0
        tasks[index].nextRetryAt = nil
        tasks[index].updatedAt = Date()
        persist(tasks[index])
        kick()
    }

    // MARK: - Worker

    /// Single serial worker. Wake-ups NEVER cancel run(): instead of
    /// cancelling the worker Task (which would propagate cancellation
    /// into the awaited download — the Phase 4 workstream-1 hard-gate
    /// bug), kick() resumes continuations parked in waitForKick.
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            defer { self?.worker = nil }
            while !Task.isCancelled {
                guard let self else { return }
                if activeTaskID != nil {
                    // A download is running; wait for it.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if let next = self.nextRunnable() {
                    await self.run(next)
                } else {
                    // Idle: wait for a kick or 5s poll fallback (covers
                    // missed kicks and backoff deadlines).
                    await self.waitForKick(timeoutNanoseconds: 5_000_000_000)
                }
            }
        }
    }

    /// Suspend until kick() signals or the timeout elapses. Resumption is
    /// cooperative (no Task cancellation involved), so waking the loop can
    /// never abort an in-flight download.
    private func waitForKick(timeoutNanoseconds: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            kickContinuations.append(continuation)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.signalKick()
            }
        }
    }

    private func signalKick() {
        let pending = kickContinuations
        kickContinuations = []
        for continuation in pending { continuation.resume() }
    }

    private func kick() {
        // Wake an idle-sleeping worker early. Never touches the worker
        // Task itself: in-flight downloads are immune to wake-ups.
        signalKick()
    }

    /// Next task the worker may run now: pending, and either never failed
    /// or whose backoff deadline has passed. Skips cleared/parked tasks.
    private func nextRunnable(now: Date = Date()) -> DownloadTask? {
        tasks.first {
            $0.state == .pending
                && ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
        }
    }

    private func run(_ task: DownloadTask) async {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        // Serial guard: exactly one download at a time, even if the worker
        // loop was re-entered (defensive; the loop also checks).
        guard activeTaskID == nil else { return }
        guard tasks[index].state == .pending else { return }
        guard let song = tasks[index].resolvedSong else {
            // Permanent: no metadata to download with. Park, don't retry.
            tasks[index].state = .failed
            tasks[index].lastError = "Missing discovery metadata; re-add this track."
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            return
        }
        // Destination: the owning sync job's playlist folder when set
        // (Add Playlist workflow), else the music root. The folder is
        // created lazily here so empty playlist folders never litter the
        // library when every download is skipped as a duplicate.
        let root = musicFolderAccess.folderURL
        let destination: URL
        if let custom = destinationForJob(tasks[index].syncJobID), root != nil {
            destination = custom
        } else if let root {
            destination = root
        } else {
            tasks[index].state = .failed
            tasks[index].lastError = "Choose a music folder first (Settings)."
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
        } catch {
            tasks[index].state = .failed
            tasks[index].lastError = "Couldn't create the download folder."
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            return
        }

        tasks[index].state = .downloading
        tasks[index].attempts += 1
        tasks[index].updatedAt = Date()
        persist(tasks[index])
        activeTaskID = task.id
        activeCancelRequested = false
        // Scoped access for custom destinations (balanced stop in the
        // settle path below — every start pairs with exactly one stop).
        let stopScope = scopeForJob?(tasks[index].syncJobID)
        // Snapshot the destination dir so partial-file cleanup can tell
        // our new files apart from pre-existing ones.
        let beforeFiles = listAudioFiles(in: destination)

        do {
            // Bind this download's subprocess to the queue task ID so
            // cancel(taskID:) terminates the right process.
            await engine.setRegistrationHint(task.id)
            // Race the backend stream against user cancellation: whichever
            // finishes first wins. The cancel branch finishes the stream
            // consumer so run() proceeds even if the backend never yields
            // again (hung subprocess killed via engine.cancel).
            let stream = try await engine.downloadTrack(
                song,
                profile: profileForJob(tasks[index].profileID),
                destination: destination
            )
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.consume(stream: stream, taskID: task.id)
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.waitForCancel(taskID: task.id)
                    // Cancel requested: stop consuming; the engine kill
                    // ends the backend. Mark here — the consumer may be
                    // parked forever on a hung stream.
                    await self.markCancelled(taskID: task.id)
                }
                // First branch to finish wins; cancel the other.
                await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            markCancelledSync(taskID: task.id)
        } catch {
            markFailedSync(taskID: task.id, error: error)
        }
        // Partial-file cleanup: a cancelled/failed run must not leave a
        // file the library could later mistake for a completed download.
        // Only removes files that appeared during THIS run.
        if let index = tasks.firstIndex(where: { $0.id == task.id }),
           tasks[index].state != .done {
            removeNewFiles(beforeFiles, in: destination)
        }
        // Balance scoped access exactly once per run, after cleanup (which
        // also touches the destination).
        stopScope?()
        activeTaskID = nil
        activeProgress = nil
    }

    private func handle(_ event: DownloadProgress, taskID: String) async {
        activeProgress = event
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch event {
        case .matching:
            tasks[index].state = .resolving
        case .downloading:
            tasks[index].state = .downloading
        case .processing:
            tasks[index].state = .processing
        case .completed(let url):
            tasks[index].state = .done
            tasks[index].outputPath = url.path
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            library.importFile(at: url, song: tasks[index].resolvedSong)
            // Global library semantics: a completed download joins every
            // playlist whose sync job owns this task (many-to-many; shared
            // tracks download once, link everywhere). Playlist identity is
            // resolved by syncJobID → playlist linkage, not by folder.
            if let syncJobID = tasks[index].syncJobID,
               let playlistID = playlistIDForJob?(syncJobID),
               let sourceURL = tasks[index].resolvedSong?.url {
                _ = library.linkTracksToPlaylist(playlistID: playlistID,
                                                 sourceURLs: [sourceURL])
            }
        }
        tasks[index].updatedAt = Date()
        persist(tasks[index])
    }

    /// Consume backend progress events until the stream ends. Runs as one
    /// branch of the run() task group; the sibling cancel branch wins the
    /// race when the user cancels a hung download.
    private func consume(stream: AsyncThrowingStream<DownloadProgress, Error>, taskID: String) async {
        do {
            for try await event in stream {
                if activeCancelRequested { break }
                await self.handle(event, taskID: taskID)
            }
        } catch is CancellationError {
            await self.markCancelled(taskID: taskID)
        } catch {
            await self.markFailed(taskID: taskID, error: error)
        }
    }

    /// Park until this task's cancel is requested. Never completes on its
    /// own — the group cancels it when the consumer branch finishes first.
    private func waitForCancel(taskID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancelWaiters[taskID] = continuation
        }
    }

    private func markFailed(taskID: String, error: Error) async {
        markFailedSync(taskID: taskID, error: error)
    }

    /// Failure routing: retryable errors (timeouts, transient backend
    /// failures) requeue as pending with persisted exponential backoff
    /// until maxAttempts, then park as failed. Non-retryable errors
    /// (bad input, missing backend, unparseable output, missing metadata)
    /// park immediately. User-requested cancellation always wins over
    /// whatever the backend reports (a SIGTERM-killed spotdl surfaces as
    /// nonZeroExit, not CancellationError).
    private func markFailedSync(taskID: String, error: Error) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if activeTaskID == taskID && activeCancelRequested {
            markCancelledSync(taskID: taskID)
            return
        }
        let retryable = (error as? DownloadEngineError)?.isRetryable ?? true
        tasks[index].lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        tasks[index].updatedAt = Date()
        if retryable && tasks[index].attempts < DownloadTask.maxAttempts {
            let delay = DownloadTask.backoffDelay(attempt: tasks[index].attempts)
            tasks[index].state = .pending
            tasks[index].nextRetryAt = Date().addingTimeInterval(delay)
            logger.error("Task failed (attempt \(tasks[index].attempts)), retrying in \(Int(delay))s: \(tasks[index].lastError ?? "unknown")")
        } else {
            tasks[index].state = .failed
            tasks[index].nextRetryAt = nil
            logger.error("Task failed permanently after \(tasks[index].attempts) attempt(s): \(tasks[index].lastError ?? "unknown")")
        }
        persist(tasks[index])
    }

    private func markCancelled(taskID: String) async {
        markCancelledSync(taskID: taskID)
    }

    private func markCancelledSync(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .cancelled
        tasks[index].updatedAt = Date()
        persist(tasks[index])
    }

#if DEBUG
    /// Test hook: clear a task's retry deadline so the worker picks it up
    /// immediately (fast-forwards backoff without waiting minutes).
    func clearRetryDeadlineForTests(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].nextRetryAt = nil
        persist(tasks[index])
        kick()
    }

    /// Test hook: stop the worker loop (simulates app termination so a
    /// fresh queue can take over the same DB without two loops racing).
    func stopForTests() {
        worker?.cancel()
        worker = nil
    }
#endif

    // MARK: - Persistence

    /// Audio extensions spotdl can produce (mirrors SpotDLEngine.findOutput).
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "opus", "flac", "ogg", "wav",
    ]

    private func listAudioFiles(in directory: URL) -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return Set(files.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .map(\.path))
    }

    /// Delete files that appeared in `directory` during this run. Only
    /// ever deletes files NOT present in `before` (never user data), and
    /// only when the task did not complete (cancelled/failed).
    private func removeNewFiles(_ before: Set<String>, in directory: URL) {
        for path in listAudioFiles(in: directory).subtracting(before) {
            try? FileManager.default.removeItem(atPath: path)
            logger.info("Cleaned partial output: \(path)")
        }
    }

    private func persist(_ task: DownloadTask) {
        let encoder = JSONEncoder()
        let resolvedJSON = task.resolvedSong.flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        do {
            try database.execute(
                """
                INSERT INTO download_tasks (id, source_url, state, created_at, updated_at, resolved_json, last_error, output_path, sync_job_id, sync_run_id, source_id, profile_id, attempts, next_retry_at, cleared_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    source_url=excluded.source_url, state=excluded.state,
                    updated_at=excluded.updated_at, resolved_json=excluded.resolved_json,
                    last_error=excluded.last_error, output_path=excluded.output_path,
                    sync_job_id=excluded.sync_job_id, sync_run_id=excluded.sync_run_id,
                    source_id=excluded.source_id, profile_id=excluded.profile_id,
                    attempts=excluded.attempts,
                    next_retry_at=excluded.next_retry_at;
                """,
                [
                    .text(task.id), .text(task.sourceURL), .text(task.state.rawValue),
                    .real(task.createdAt.timeIntervalSince1970), .real(task.updatedAt.timeIntervalSince1970),
                    resolvedJSON.map(SQLiteValue.text) ?? .null,
                    task.lastError.map(SQLiteValue.text) ?? .null,
                    task.outputPath.map(SQLiteValue.text) ?? .null,
                    task.syncJobID.map(SQLiteValue.text) ?? .null,
                    task.syncRunID.map(SQLiteValue.text) ?? .null,
                    task.sourceID.map(SQLiteValue.text) ?? .null,
                    task.profileID.map(SQLiteValue.text) ?? .null,
                    .integer(task.attempts),
                    task.nextRetryAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                ]
            )
        } catch {
            logger.error("Task persist failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            // Cleared tombstones (cleared_at NOT NULL) stay in SQLite for
            // history but never re-enter the visible queue — recovery
            // cannot resurrect an intentionally cleared task.
            let rows = try database.query(
                "SELECT id, source_url, state, created_at, updated_at, resolved_json, last_error, output_path, sync_job_id, sync_run_id, source_id, profile_id, attempts, next_retry_at FROM download_tasks WHERE cleared_at IS NULL ORDER BY created_at;"
            )
            let decoder = JSONDecoder()
            tasks = rows.compactMap { row in
                guard let id = row["id"]?.text,
                      let sourceURL = row["source_url"]?.text,
                      let stateRaw = row["state"]?.text,
                      let state = DownloadState(rawValue: stateRaw)
                else { return nil }
                var song: ResolvedSong?
                if let json = row["resolved_json"]?.text,
                   let data = json.data(using: .utf8) {
                    song = try? decoder.decode(ResolvedSong.self, from: data)
                }
                return DownloadTask(
                    id: id,
                    sourceURL: sourceURL,
                    state: state,
                    createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                    updatedAt: row["updated_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                    resolvedSong: song,
                    lastError: row["last_error"]?.text,
                    outputPath: row["output_path"]?.text,
                    syncJobID: row["sync_job_id"]?.text,
                    syncRunID: row["sync_run_id"]?.text,
                    sourceID: row["source_id"]?.text,
                    profileID: row["profile_id"]?.text,
                    attempts: row["attempts"]?.integer ?? 0,
                    nextRetryAt: row["next_retry_at"]?.real.map(Date.init(timeIntervalSince1970:))
                )
            }
        } catch {
            logger.error("Queue load failed: \(error.localizedDescription)")
        }
    }

    /// Tasks active at termination can never complete: their subprocess
    /// died with the previous launch. Reset to pending for retry, keeping
    /// attempts (backoff continues rather than restarting). Cleared rows
    /// are excluded by the WHERE clause — tombstones stay buried.
    private func recoverInterruptedTasks() {
        do {
            try database.execute(
                "UPDATE download_tasks SET state='pending', updated_at=? WHERE cleared_at IS NULL AND state IN ('resolving','downloading','processing');",
                [.real(Date().timeIntervalSince1970)]
            )
        } catch {
            logger.error("Queue recovery failed: \(error.localizedDescription)")
        }
    }
}
