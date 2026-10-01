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
/// `spotdl save --preload`. Phase 3 added sync-job linkage. Phase 4 adds
/// retry state: `attempts` counts completed attempts (persisted, survives
/// restart); `nextRetryAt` gates the worker until backoff elapses.
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
    /// Originating sync job/run/source (nil for one-off Phase 1/2 downloads).
    var syncJobID: String?
    var syncRunID: String?
    var sourceID: String?
    /// DownloadProfile ID to use for this task. Set at enqueue time: the
    /// sync job's profile for job tasks, the global default for one-offs.
    /// Persisted so restarts and retries keep the same profile even if the
    /// user later changes the default. Nil (pre-v5 rows) = default.
    var profileID: String?
    /// Completed attempts (failures + successes). Reset on manual retry.
    var attempts: Int
    /// Earliest date the worker may run this task again. Nil = runnable now.
    var nextRetryAt: Date?

    /// Bounded exponential backoff: 1m, 2m, 4m … capped at 1h.
    /// Matches SyncScheduler2.backoff (duplicated here so the queue stays
    /// independent of the scheduler module).
    static func backoffDelay(attempt: Int) -> TimeInterval {
        min(60 * pow(2.0, Double(max(0, attempt))), 3600)
    }

    /// Maximum automatic attempts before a task parks as failed-permanent
    /// and waits for manual retry. SyncEngine re-detects un-downloaded
    /// tracks on later runs regardless (snapshot-driven), so parking is
    /// safe: it stops hammering, not syncing.
    static let maxAttempts = 5

    init(id: String = UUID().uuidString, sourceURL: String,
         state: DownloadState = .pending,
         createdAt: Date = Date(), updatedAt: Date = Date(),
         resolvedSong: ResolvedSong? = nil, lastError: String? = nil,
         outputPath: String? = nil, syncJobID: String? = nil,
         syncRunID: String? = nil, sourceID: String? = nil,
         profileID: String? = nil,
         attempts: Int = 0, nextRetryAt: Date? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedSong = resolvedSong
        self.lastError = lastError
        self.outputPath = outputPath
        self.syncJobID = syncJobID
        self.syncRunID = syncRunID
        self.sourceID = sourceID
        self.profileID = profileID
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
    }
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

    /// Hint consumed by the next downloadTrack call to register the
    /// subprocess under the queue's task ID, so cancel(taskID:) can kill
    /// it. Set via setRegistrationHint (actor-isolated mutation from the
    /// queue's actor). Default nil (engines without subprocesses ignore it).
    var registrationHint: String? { get }
    func setRegistrationHint(_ id: String?) async
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
