import Foundation

/// Runs subprocesses off the main thread with cancellation support.
/// The ONLY place that spawns backend processes (spotDL/yt-dlp/ffmpeg).
/// Views and stores call DownloadEngine; engines call this runner.
actor ProcessRunner {
    struct Result: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a binary. Throws on non-zero exit or cancellation.
    /// No shell interpolation: executable path + argv array only,
    /// never a shell string.
    func run(executable: URL, arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.terminationHandler = { _ in
                    let stdout = String(
                        data: out.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: err.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: Result(
                            exitCode: 0, stdout: stdout, stderr: stderr
                        ))
                    } else {
                        continuation.resume(throwing: ProcessError.nonZeroExit(
                            code: process.terminationStatus, stderr: stderr
                        ))
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Locate a backend binary. Phase 0: dev-machine PATH lookup.
    /// Phase 6 replaces this with bundled Resources binaries.
    nonisolated func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

enum ProcessError: Error {
    case nonZeroExit(code: Int32, stderr: String)
}
