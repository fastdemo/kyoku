import Foundation

/// First DownloadEngine implementation, backed by spotDL.
/// Phase 0: availability probing only. Full resolve/download in Phase 1.
actor SpotDLEngine: DownloadEngine {
    private let runner: ProcessRunner
    private let logger = KyokuLogger(subsystem: "engine", category: "spotdl")

    init(runner: ProcessRunner) {
        self.runner = runner
    }

    /// Whether the spotdl binary is reachable (dev PATH or bundled Resources).
    func isAvailable() async -> Bool {
        if bundledBinary() != nil { return true }
        return runner.locate("spotdl") != nil
    }

    func resolveSource(_ url: String) async throws -> [DiscoveredTrack] {
        // Phase 1: `spotdl save` / URL resolution goes here.
        logger.info("resolveSource stub (Phase 1): \(url)")
        return []
    }

    func downloadTrack(_ task: DownloadTask) async throws {
        // Phase 1: queued download goes here.
        logger.info("downloadTrack stub (Phase 1): \(task.id)")
    }

    func cancel(taskID: String) async {
        logger.info("cancel stub (Phase 1): \(taskID)")
    }

    // MARK: - Private

    private nonisolated func bundledBinary() -> URL? {
        Bundle.main.url(forResource: "spotdl", withExtension: nil, subdirectory: "Backend")
    }
}
