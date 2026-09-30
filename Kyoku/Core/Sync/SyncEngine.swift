import Combine
import Foundation

/// Coordinates one sync job end-to-end: resolve → diff → enqueue →
/// observe downloads → snapshot → records. Does NOT download itself
/// (DownloadQueue does) and never touches SwiftUI.
///
/// Lifecycle per run:
///   1. begin SyncRun row (status=running)
///   2. resolveSource via DownloadEngine (cancellable, generous timeouts)
///   3. diff against persisted snapshot → ChangeSet
///   4. enqueue added+changed via DownloadQueue (tagged syncJobID+runID)
///   5. observe queue until our tasks settle (poll, not block)
///   6. persist new snapshot (only successfully-handled entries advance;
///      failed entries stay "new" next run → natural retry)
///   7. finish SyncRun, Attention items for failures, Activity event,
///      aggregated notification.
///
/// Cancellation: the in-flight resolve/download observation checks
/// Task.isCancelled each poll tick; resolve cancels the subprocess.
@MainActor
final class SyncEngine: ObservableObject {
    /// Progress for the UI (Sync Now sheet / job row). Nil when idle.
    @Published private(set) var progress: SyncProgress?
    @Published private(set) var activeJobID: String?

    struct SyncProgress: Equatable, Sendable {
        var jobID: String
        var phase: String
        var totalTracks: Int = 0
        var doneTracks: Int = 0
    }

    private let database: Database
    private let engine: any DownloadEngine
    private let queue: DownloadQueue
    private let library: LibraryStore
    private let sources: SourceStore
    private let jobs: SyncJobStore
    private let records: AutomationRecordStore
    private let musicFolderAccess: MusicFolderAccess
    private let logger = KyokuLogger(subsystem: "core", category: "sync-engine")

    /// Poll interval while waiting for downloads to settle.
    private let settlePoll: TimeInterval = 5
    /// Max wait for downloads per run before finishing as partial
    /// (downloads continue in the queue; the NEXT run picks up state).
    private let settleTimeout: TimeInterval = 1800

    /// Nonisolated init (cf. DownloadQueue): pure dependency storage,
    /// no actor-bound work. Runs happen via run() on the main actor.
    nonisolated init(database: Database, engine: any DownloadEngine, queue: DownloadQueue,
         library: LibraryStore, sources: SourceStore, jobs: SyncJobStore,
         records: AutomationRecordStore, musicFolderAccess: MusicFolderAccess) {
        self.database = database
        self.engine = engine
        self.queue = queue
        self.library = library
        self.sources = sources
        self.jobs = jobs
        self.records = records
        self.musicFolderAccess = musicFolderAccess
    }

    // MARK: - Entry points

    /// Run one job now (manual Sync Now or scheduler-due). No overlap:
    /// returns nil when this job already has an active run.
    @discardableResult
    func run(jobID: String, dryRun: Bool = false) async -> SyncRun? {
        guard let job = jobs.jobs.first(where: { $0.id == jobID }) else { return nil }
        guard let source = sources.sources.first(where: { $0.id == job.sourceID }) else {
            logger.error("Sync run: source missing for job \(job.name)")
            return nil
        }
        guard activeJobID == nil else {
            logger.info("Sync run: another job active, skipping \(job.name)")
            return nil
        }
        activeJobID = jobID
        defer { activeJobID = nil; progress = nil }

        var run = records.beginRun(syncJobID: jobID)
        setPhase(jobID: jobID, phase: "Resolving source…")

        // 1. Resolve.
        let discovered: [DiscoveredTrack]
        do {
            discovered = try await engine.resolveSource(source.url)
        } catch is CancellationError {
            run.status = .cancelled
            run.finishedAt = Date()
            records.finishRun(run)
            records.logActivity(syncJobID: jobID, kind: "cancelled",
                                title: "\(job.name): sync cancelled")
            return run
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            run.status = .failed
            run.error = message
            run.finishedAt = Date()
            records.finishRun(run)
            jobs.recordRunOutcome(id: jobID, success: false, error: message)
            sources.recordCheck(id: source.id, success: false, error: message)
            records.addAttention(AttentionItem(
                kind: "sourceFailed", title: "\(job.name): source check failed",
                detail: message, syncJobID: jobID, sourceURL: source.url))
            records.logActivity(syncJobID: jobID, kind: "failed",
                                title: "\(job.name): sync failed", detail: message)
            notify(title: "Kyoku: sync failed",
                   body: "\(job.name): \(message)")
            return run
        }
        if Task.isCancelled {
            run.status = .cancelled
            run.finishedAt = Date()
            records.finishRun(run)
            return run
        }

        // 2. Diff.
        setPhase(jobID: jobID, phase: "Comparing changes…", total: discovered.count)
        let current = discovered.enumerated().map { SnapshotEntry.from(song: $0.element.song, position: $0.offset) }
        let previous = sources.loadSnapshot(sourceID: source.id)
        // First sync (no snapshot yet): everything counts as added; the
        // library/queue dedupe below still prevents re-downloads.
        // NOTE: AddSourceView saves a snapshot at job creation from the
        // same discovery, so a UI-created job's first run diffs against
        // that (usually no-op) — sync state stays consistent either way.
        let changes: ChangeSet
        if previous.isEmpty {
            changes = ChangeSet(added: current, unchangedCount: 0)
        } else {
            changes = ChangeSet.diff(old: previous, new: current)
        }
        // Map added/changed entries back to songs for enqueue.
        let songByKey = Dictionary(
            discovered.map { (SnapshotEntry.key(for: $0.song, position: 0), $0.song) },
            uniquingKeysWith: { first, _ in first })
        // NOTE: key() ignores position, so lookup is position-independent.
        run.addedCount = changes.added.count
        run.removedCount = changes.removed.count
        run.changedCount = changes.changed.count
        run.unchangedCount = changes.unchangedCount

        if dryRun {
            run.status = .succeeded
            run.finishedAt = Date()
            // Dry runs don't persist anything; the caller reads the counts.
            // Still finish the run row so Activity can show the preview.
            records.finishRun(run)
            return run
        }

        // 3. Handle removals per policy (before downloads so state is clear).
        handleRemovals(job: job, changes: changes, run: &run)

        // 4. Enqueue additions + changed.
        let toDownload = (changes.added + changes.changed.map(\.new))
            .compactMap { songByKey[$0.key] }
        // Dedupe against already-queued/downloaded: skip songs whose URL
        // already has a non-failed task from this job, or is in the library.
        let existingTaskURLs = Set(queue.tasks.map(\.sourceURL))
        let libraryURLs = Set(library.tracks.compactMap(\.sourceURL))
        let fresh = toDownload.filter {
            !existingTaskURLs.contains($0.url) && !libraryURLs.contains($0.url)
        }
        run.queuedCount = fresh.count
        if !fresh.isEmpty {
            setPhase(jobID: jobID, phase: "Queueing \(fresh.count) download(s)…", total: discovered.count)
            queue.enqueue(fresh, sourceURL: source.url, syncJobID: job.id, syncRunID: run.id, sourceID: source.id)
        }

        // 5. Observe until our tasks settle (or timeout → partial).
        if !fresh.isEmpty {
            await observeTasks(urls: Set(fresh.map(\.url)), run: &run, jobID: jobID)
        }

        // 6. Advance snapshot: keep previous entries for failed tracks so
        // they stay "added" next run; everything else advances to current.
        let failedURLs = Set(failedTaskURLs(syncRunID: run.id))
        var nextSnapshot = current
        if !failedURLs.isEmpty {
            // Drop failed entries from the new snapshot only if they were
            // NOT in the previous snapshot (still need download). If they
            // were previously synced, keep the OLD entry (don't regress).
            let prevKeys = Set(previous.map(\.key))
            nextSnapshot = current.filter { entry in
                guard failedURLs.contains(entry.url) else { return true }
                return prevKeys.contains(entry.key)
            }
        }
        sources.saveSnapshot(sourceID: source.id, entries: nextSnapshot)
        sources.recordCheck(id: source.id, success: run.failedCount == 0,
                            error: run.failedCount == 0 ? nil : "\(run.failedCount) download(s) failed")

        // 7. Finish records.
        run.finishedAt = Date()
        if run.failedCount > 0 && run.downloadedCount > 0 {
            run.status = .partiallySucceeded
        } else if run.failedCount > 0 && run.queuedCount > 0 {
            run.status = .failed
        } else if run.failedCount > 0 {
            run.status = .partiallySucceeded
        } else {
            run.status = .succeeded
        }
        records.finishRun(run)
        let ok = run.status == .succeeded
        jobs.recordRunOutcome(id: jobID, success: ok,
                              error: ok ? nil : (run.error ?? "\(run.failedCount) failed"))

        // Attention for failures (deduped by track URL).
        createAttentionForFailures(job: job, runID: run.id)

        // Activity + notification (aggregated per run).
        let summary = summarize(job: job, run: run)
        records.logActivity(syncJobID: jobID,
                            kind: run.status.rawValue,
                            title: "\(job.name): \(summary.title)",
                            detail: summary.detail)
        notify(title: "Kyoku: \(job.name)",
               body: summary.detail.isEmpty ? summary.title : "\(summary.title). \(summary.detail)")
        return run
    }

    /// Preview without side effects: resolve + diff + counts.
    func preview(jobID: String) async -> (changes: ChangeSet, total: Int)? {
        guard let job = jobs.jobs.first(where: { $0.id == jobID }),
              let source = sources.sources.first(where: { $0.id == job.sourceID })
        else { return nil }
        setPhase(jobID: jobID, phase: "Resolving source…")
        do {
            let discovered = try await engine.resolveSource(source.url)
            let current = discovered.enumerated().map {
                SnapshotEntry.from(song: $0.element.song, position: $0.offset)
            }
            let previous = sources.loadSnapshot(sourceID: source.id)
            let changes = ChangeSet.diff(old: previous, new: current)
            progress = nil
            return (changes, discovered.count)
        } catch {
            progress = nil
            return nil
        }
    }

    /// Mark interrupted 'running' runs as failed at launch (their
    /// subprocesses died). Queued tasks recover via DownloadQueue's own
    /// recovery; snapshots stay at last-good state so the next run
    /// re-detects anything missing.
    func recoverInterruptedRuns() {
        let interrupted = records.interruptedRuns()
        guard !interrupted.isEmpty else { return }
        logger.info("Recovering \(interrupted.count) interrupted sync run(s).")
        for var run in interrupted {
            run.status = .failed
            run.error = "Interrupted by app restart"
            run.finishedAt = Date()
            records.finishRun(run)
            records.logActivity(syncJobID: run.syncJobID, kind: "failed",
                                title: "Sync interrupted by restart",
                                detail: "The next scheduled check will resume.")
        }
    }

    // MARK: - Private

    private func setPhase(jobID: String, phase: String, total: Int = 0) {
        progress = SyncProgress(jobID: jobID, phase: phase, totalTracks: total)
    }

    private func handleRemovals(job: SyncJobConfig, changes: ChangeSet, run: inout SyncRun) {
        guard !changes.removed.isEmpty else { return }
        // Only act on removals the user can still evaluate: entries whose
        // tracks are actually in the library (imported through a previous
        // sync). Stale snapshot entries with no library track are dropped
        // silently under every policy — there is nothing to remove and
        // nothing to ask about.
        let actionable = changes.removed.filter { entry in
            library.tracks.contains { $0.sourceURL == entry.url }
        }
        guard !actionable.isEmpty else {
            logger.info("Removals detected but no library tracks affected; ignoring.")
            return
        }
        switch job.removalPolicy {
        case .keep:
            logger.info("Removal policy keep: \(actionable.count) stale entries ignored.")
        case .delete:
            // Remove library tracks whose source URL matches a removed
            // entry AND that came from this job's source. Files stay on
            // disk (library removal ≠ file deletion); the song file is
            // only deleted via the explicit Delete File action.
            var removed = 0
            for entry in actionable {
                if let track = library.tracks.first(where: { $0.sourceURL == entry.url }) {
                    library.removeFromLibrary(trackID: track.id)
                    removed += 1
                }
            }
            logger.info("Removal policy delete: removed \(removed) library track(s).")
        case .ask:
            // One attention item per removed track (deduped).
            for entry in actionable {
                if records.openItemForTrack(kind: "removalPending", trackURL: entry.url) == nil {
                    records.addAttention(AttentionItem(
                        kind: "removalPending",
                        title: "Removed from source: \(entry.artist) – \(entry.title)",
                        detail: "“\(job.name)” no longer lists this track. Remove it from your library, or keep it.",
                        syncJobID: job.id, sourceURL: job.sourceID, trackURL: entry.url))
                }
            }
        }
    }

    /// Poll the queue until every task for our URLs reaches a terminal
    /// state (done/failed/cancelled), or timeout. Updates run counts.
    private func observeTasks(urls: Set<String>, run: inout SyncRun, jobID: String) async {
        setPhase(jobID: jobID, phase: "Downloading…", total: urls.count)
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            let relevant = queue.tasks.filter { urls.contains($0.sourceURL) }
            let done = relevant.filter { $0.state == .done }.count
            let failed = relevant.filter { $0.state == .failed }.count
            let settled = relevant.filter {
                $0.state == .done || $0.state == .failed || $0.state == .cancelled
            }.count
            run.downloadedCount = done
            run.failedCount = failed
            progress = SyncProgress(jobID: jobID, phase: "Downloading…",
                                    totalTracks: urls.count, doneTracks: settled)
            if settled >= relevant.count && relevant.count >= urls.count {
                break
            }
            // Tasks may still be resolving into existence; also break when
            // the queue has no pending/active work left for us.
            let active = relevant.contains {
                $0.state == .pending || $0.state == .resolving
                    || $0.state == .downloading || $0.state == .processing
            }
            if !active && settled >= urls.count { break }
            try? await Task.sleep(nanoseconds: UInt64(settlePoll * 1_000_000_000))
        }
        // Final count sync.
        let relevant = queue.tasks.filter { urls.contains($0.sourceURL) }
        run.downloadedCount = relevant.filter { $0.state == .done }.count
        run.failedCount = relevant.filter { $0.state == .failed }.count
    }

    private func failedTaskURLs(syncRunID: String) -> [String] {
        queue.tasks.filter { $0.syncRunID == syncRunID && $0.state == .failed }
            .map(\.sourceURL)
    }

    private func createAttentionForFailures(job: SyncJobConfig, runID: String) {
        for task in queue.tasks where task.syncRunID == runID && task.state == .failed {
            guard let url = task.resolvedSong?.url ?? Optional(task.sourceURL) else { continue }
            if records.openItemForTrack(kind: "downloadFailed", trackURL: url) != nil { continue }
            let title = task.resolvedSong.map { "\($0.artist) – \($0.name)" } ?? task.sourceURL
            records.addAttention(AttentionItem(
                kind: "downloadFailed", title: "Download failed: \(title)",
                detail: task.lastError ?? "Unknown error",
                syncJobID: job.id, trackURL: url, taskID: task.id))
        }
    }

    private func summarize(job: SyncJobConfig, run: SyncRun) -> (title: String, detail: String) {
        switch run.status {
        case .succeeded:
            if run.addedCount == 0 && run.queuedCount == 0 {
                return ("Up to date", "\(run.unchangedCount) tracks, no changes.")
            }
            return ("Synchronized",
                    "+\(run.addedCount) new, \(run.downloadedCount) downloaded.")
        case .partiallySucceeded:
            return ("Partially synchronized",
                    "+\(run.addedCount) new, \(run.downloadedCount) downloaded, \(run.failedCount) failed.")
        case .failed:
            return ("Sync failed", run.error ?? "\(run.failedCount) download(s) failed.")
        case .cancelled:
            return ("Sync cancelled", "")
        case .running:
            return ("Sync running", "")
        }
    }

    private func notify(title: String, body: String) {
        // Guard: UNUserNotificationCenter crashes in non-app processes
        // (bundleProxyForCurrentProcess is nil for CLI tools). Only post
        // from a real .app bundle; the E2E runner links this file and
        // would otherwise crash at the end of a successful sync.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        SyncNotifier.post(title: title, body: body)
    }
}
