import Foundation

/// Typed playback failures. Small on purpose: every case maps to one
/// honest UI state (PlayerBar/Now Playing show `displayMessage`, never
/// raw internals). Failures never count toward play history.
enum PlaybackError: Error, Equatable, Sendable {
    /// No localPath, or the file vanished from disk.
    case fileUnavailable(trackTitle: String)
    /// AVPlayerItem entered .failed, or FailedToPlayToEndTime fired.
    case undecodable(trackTitle: String, underlying: String?)
    /// Seek impossible (no item, no duration yet, item failed).
    case seekUnavailable
    /// Audio route/interruption stopped playback (reserved for the
    /// interruption observer; currently surfaced as paused + message).
    case interrupted

    var displayMessage: String {
        switch self {
        case .fileUnavailable(let title):
            return "File not found: \(title)"
        case .undecodable(let title, _):
            return "Couldn't play \(title) — the file appears to be corrupt or unsupported."
        case .seekUnavailable:
            return "Seek isn't available right now."
        case .interrupted:
            return "Playback was interrupted."
        }
    }
}
