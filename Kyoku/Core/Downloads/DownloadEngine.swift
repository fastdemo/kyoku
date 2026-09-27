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
///
/// Phase 1: `resolvedSong` carries discovery metadata (title/artist/album,
/// duration, cover URL, candidate download URL) decoded from
/// `spotdl save --preload`. Phase 3 adds retry counts, error detail,
/// and sync-job linkage.
struct DownloadTask: Identifiable, Sendable {
    let id: String
    var sourceURL: String
    var state: DownloadState
    var createdAt: Date
    var updatedAt: Date
    /// Discovery metadata, when the task was created from a resolved song.
    var resolvedSong: ResolvedSong?
    /// User-facing failure reason for the Needs Attention surface.
    var lastError: String?
    /// Local file produced by a completed download.
    var outputPath: String?
}

/// Internal API the whole app programs against. First impl: SpotDLEngine.
/// UI/views must never shell out directly — only through this protocol.
///
/// Concurrency: resolve/download run on background tasks and post
/// progress via AsyncStream, so views observe without polling.
/// Cancellation is cooperative via Swift task cancellation.
protocol DownloadEngine: Actor, Sendable {
    /// Classify a URL without network access. Unknown strings are
    /// treated as search terms, never rejected.
    func classifySource(_ input: String) -> SourceKind

    /// Discover tracks for a source: single track, search term, or
    /// Spotify/YouTube playlist/album/artist URL. Long-running; cancel
    /// by cancelling the awaiting task.
    func resolveSource(_ url: String) async throws -> [DiscoveredTrack]

    /// Download one resolved track into `destination` using `profile`.
    /// Progress events stream until completion or cancellation.
    /// Returns the final local file URL.
    func downloadTrack(
        _ song: ResolvedSong,
        profile: DownloadProfile,
        destination: URL
    ) async throws -> AsyncThrowingStream<DownloadProgress, Error>

    /// Cancel in-flight work for a task. Best-effort; the awaiting task
    /// also observes Swift cancellation directly.
    func cancel(taskID: String) async
}

/// What kind of source a user-provided string looks like.
/// Classification is syntactic only (no network); resolution may still
/// fail if the URL is invalid or unreachable.
enum SourceKind: Hashable, Sendable {
    case spotifyTrack
    case spotifyPlaylist
    case spotifyAlbum
    case spotifyArtist
    case youTubeVideo
    case youTubePlaylist
    case youTubeMusicLink
    case spotdlFile
    /// Anything else — passed to spotDL as a search term.
    case searchTerm
}

/// Metadata discovered for a source URL, before matching/downloading.
///
/// `song` is the full spotDL record; convenience accessors expose the
/// fields views and the matching engine need most often.
struct DiscoveredTrack: Sendable, Hashable, Identifiable {
    var id: String { song.songID }
    var song: ResolvedSong
    /// Candidate audio URL from `--preload` (may be nil without preload
    /// or when no provider matched). Not a quality signal on its own —
    /// the matching engine scores candidates in Phase 1b/3.
    var candidateURL: String?

    var title: String { song.name }
    var artist: String { song.artist }
}

/// Progress events for one download, in pipeline order.
enum DownloadProgress: Sendable {
    /// Match/search phase (resolving metadata, finding audio).
    case matching(String)
    /// Byte-level progress, 0.0–1.0 when the backend reports it.
    case downloading(fraction: Double?)
    /// Post-processing: conversion, metadata/artwork/lyrics embedding.
    case processing(String)
    /// Finished; carries the final file location.
    case completed(URL)
}
