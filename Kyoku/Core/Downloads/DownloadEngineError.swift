import Foundation

/// Errors surfaced by the download engine. Mapped to user-actionable
/// messages in views; raw stderr is preserved for advanced users/logs.
enum DownloadEngineError: Error, LocalizedError {
    /// spotdl binary not found (dev PATH or bundled Resources).
    case backendMissing
    /// Non-zero exit from a spotdl invocation.
    case backendFailed(exitCode: Int32, message: String)
    /// spotdl output could not be parsed (schema drift, corruption).
    case parseFailed(String)
    /// Timed out waiting for spotdl.
    case timedOut(operation: String)
    /// Invalid input (empty query, unsupported URL).
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .backendMissing:
            return "Download backend not found. Install spotdl or wait for the bundled backend (Phase 6)."
        case .backendFailed(_, let message):
            return "Download failed: \(message)"
        case .parseFailed(let detail):
            return "Could not understand the download result (\(detail))."
        case .timedOut(let operation):
            return "\(operation) timed out. Check your connection and try again."
        case .invalidInput(let detail):
            return detail
        }
    }
}
