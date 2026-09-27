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
    private let logger = KyokuLogger(subsystem: "core", category: "queue")

    private var worker: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    /// DownloadQueue is @MainActor but constructed from AppContainer's
    /// nonisolated init: keep init nonisolated and do the actor-bound work
    /// (DB recovery + load + worker start) on first use instead.
    nonisolated init(
        database: Database,
        engine: any DownloadEngine,
        library: LibraryStore,
        musicFolderAccess: MusicFolderAccess
    ) {
        self.database = database
        self.engine = engine
        self.library = library
        self.musicFolderAccess = musicFolderAccess
    }

    /// Must be called once from the main thread after construction.
    /// (Split from init because AppContainer.init is nonisolated.)
    func start() {
        recoverInterruptedTasks()
        load()
        startWorker()
    }

    // MARK: - Public API

    /// Enqueue resolved songs for download. Skips songs already queued
    /// (by Spotify URL) so re-resolving a source is idempotent.
    func enqueue(_ songs: [ResolvedSong], sourceURL: String) {
        let existing = Set(tasks.map(\.sourceURL))
        var added = 0
        for song in songs where !existing.contains(song.url) {
            let now = Date()
            let task = DownloadTask(
                id: UUID().uuidString,
                sourceURL: song.url,
                state: .pending,
                createdAt: now,
                updatedAt: now,
                resolvedSong: song
            )
            persist(task)
            tasks.append(task)
            added += 1
        }
        logger.info("Enqueued \(added) tasks from \(sourceURL) (\(songs.count - added) duplicates skipped).")
        kick()
    }

    /// Cancel a pending task, or stop the active download.
    func cancel(taskID: String) {
        if activeTaskID == taskID {
            streamTask?.cancel()
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .cancelled
        tasks[index].updatedAt = Date()
        persist(tasks[index])
    }

    /// Drop finished/failed/cancelled tasks from the visible queue.
    /// History beyond this lives in the library (completed) and logs.
    func clearFinished() {
        tasks.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
        // Re-persist remaining; cleared rows stay in SQLite as a record.
        // (Phase 3 may surface history from these rows.)
    }

    /// Retry a failed task.
    func retry(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .pending
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        persist(tasks[index])
        kick()
    }

    // MARK: - Worker

    private func startWorker() {
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let next = self.tasks.first(where: { $0.state == .pending }) {
                    await self.run(next)
                } else {
                    // Idle: sleep until kicked or 5s passes (poll fallback
                    // in case a kick is missed; cheap and bounded).
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func kick() {
        // Wake the worker early by cancelling its sleep: the loop
        // re-checks for pending tasks immediately.
        worker?.cancel()
        startWorker()
    }

    private func run(_ task: DownloadTask) async {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard let song = tasks[index].resolvedSong else {
            tasks[index].state = .failed
            tasks[index].lastError = "Missing discovery metadata; re-add this track."
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            return
        }
        guard let destination = musicFolderAccess.folderURL else {
            tasks[index].state = .failed
            tasks[index].lastError = "Choose a music folder first (Settings)."
            tasks[index].updatedAt = Date()
            persist(tasks[index])
            return
        }

        tasks[index].state = .downloading
        tasks[index].updatedAt = Date()
        persist(tasks[index])
        activeTaskID = task.id

        do {
            let stream = try await engine.downloadTrack(
                song,
                profile: .appleLibrary,
                destination: destination
            )
            streamTask = Task {
                do {
                    for try await event in stream {
                        await self.handle(event, taskID: task.id)
                    }
                } catch is CancellationError {
                    await self.markCancelled(taskID: task.id)
                } catch {
                    await self.markFailed(taskID: task.id, error: error)
                }
            }
            await streamTask?.value
        } catch is CancellationError {
            markCancelledSync(taskID: task.id)
        } catch {
            markFailedSync(taskID: task.id, error: error)
        }
        activeTaskID = nil
        activeProgress = nil
        streamTask = nil
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
        }
        tasks[index].updatedAt = Date()
        persist(tasks[index])
    }

    private func markFailed(taskID: String, error: Error) async {
        markFailedSync(taskID: taskID, error: error)
    }

    private func markFailedSync(taskID: String, error: Error) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = .failed
        tasks[index].lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        tasks[index].updatedAt = Date()
        persist(tasks[index])
        logger.error("Task failed: \(tasks[index].lastError ?? "unknown")")
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

    // MARK: - Persistence

    private func persist(_ task: DownloadTask) {
        let encoder = JSONEncoder()
        let resolvedJSON = task.resolvedSong.flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        do {
            try database.execute(
                """
                INSERT INTO download_tasks (id, source_url, state, created_at, updated_at, resolved_json, last_error, output_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_url=excluded.source_url, state=excluded.state,
                    updated_at=excluded.updated_at, resolved_json=excluded.resolved_json,
                    last_error=excluded.last_error, output_path=excluded.output_path;
                """,
                [
                    .text(task.id), .text(task.sourceURL), .text(task.state.rawValue),
                    .real(task.createdAt.timeIntervalSince1970), .real(task.updatedAt.timeIntervalSince1970),
                    resolvedJSON.map(SQLiteValue.text) ?? .null,
                    task.lastError.map(SQLiteValue.text) ?? .null,
                    task.outputPath.map(SQLiteValue.text) ?? .null,
                ]
            )
        } catch {
            logger.error("Task persist failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            let rows = try database.query(
                "SELECT id, source_url, state, created_at, updated_at, resolved_json, last_error, output_path FROM download_tasks ORDER BY created_at;"
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
                    outputPath: row["output_path"]?.text
                )
            }
        } catch {
            logger.error("Queue load failed: \(error.localizedDescription)")
        }
    }

    /// Tasks active at termination can never complete: their subprocess
    /// died with the previous launch. Reset to pending for retry.
    private func recoverInterruptedTasks() {
        do {
            try database.execute(
                "UPDATE download_tasks SET state='pending', updated_at=? WHERE state IN ('resolving','downloading','processing');",
                [.real(Date().timeIntervalSince1970)]
            )
        } catch {
            logger.error("Queue recovery failed: \(error.localizedDescription)")
        }
    }
}
