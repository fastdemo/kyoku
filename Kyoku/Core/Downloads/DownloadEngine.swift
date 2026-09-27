import Foundation

/// States a download task moves through. Persisted in `download_tasks`.
enum DownloadState: String, Sendable {
    case pending
    case resolving
    case downloading
    case processing
    case done
    case failed
    case cancelled
}

/// A unit of download work. Persisted so restarts don't destroy the queue.
struct DownloadTask: Identifiable, Sendable {
    let id: String
    var sourceURL: String
    var state: DownloadState
    var createdAt: Date
    var updatedAt: Date
}

/// Internal API the whole app programs against. First impl: SpotDLEngine.
/// UI/views must never shell out directly — only through this protocol.
protocol DownloadEngine: Sendable {
    func resolveSource(_ url: String) async throws -> [DiscoveredTrack]
    func downloadTrack(_ task: DownloadTask) async throws
    func cancel(taskID: String) async
}

/// Metadata discovered for a source URL, before matching/downloading.
struct DiscoveredTrack: Sendable, Hashable {
    var title: String
    var artist: String
    var sourceURL: String
}
