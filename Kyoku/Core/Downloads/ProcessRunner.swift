import Foundation

/// Runs subprocesses off the main thread with cancellation support.
/// The ONLY place that spawns backend processes (spotDL/yt-dlp/ffmpeg).
/// Views and stores call DownloadEngine; engines call this runner.
///
/// Design notes:
/// - argv arrays only, never shell strings (no interpolation risk).
/// - Cancellation and timeouts kill the subprocess (SIGTERM, escalated
///   to SIGKILL). The wait loop polls so it never blocks a thread.
/// - Both pipes drain incrementally: spotDL discovery output can exceed
///   the 64KB pipe buffer on large playlists, which would deadlock a
///   capture-at-exit design.
/// - `onLine` streams stderr lines for progress reporting. spotDL logs to
///   stderr and writes result payloads (save JSON) to stdout, so progress
///   parsing never touches stdout.
actor ProcessRunner {
    struct Result: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Registered subprocess handles, keyed by caller-supplied ID.
    /// Lets engines kill a specific process without holding the task.
    private var processes: [String: Process] = [:]

    /// Run a binary. Throws ProcessError on non-zero exit, timeout, or
    /// launch failure. Throws CancellationError when the awaiting task
    /// is cancelled. Pass timeout 0 to disable the watchdog.
    func run(
        executable: URL,
        arguments: [String],
        registration: String? = nil,
        timeout: TimeInterval = 0,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Incremental drain. Boxes are thread-safe; handlers fire on
        // background queues while the actor polls below.
        let outBox = DataBox()
        let errBox = DataBox()
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBox.append(chunk) }
        }
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errBox.append(chunk)
            guard let onLine,
                  let text = String(data: chunk, encoding: .utf8)
            else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { onLine(trimmed) }
            }
        }

        if let registration {
            processes[registration] = process
        }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            if let registration {
                processes.removeValue(forKey: registration)
            }
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        let deadline: Date? = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        var timedOut = false

        // Poll for exit. Checks cancellation and the deadline each tick,
        // so no separate watchdog task (and no Sendable escapes) needed.
        while process.isRunning {
            if Task.isCancelled {
                terminateAndReap(process)
                cleanup(handles: [outHandle, errHandle], registration: registration)
                throw CancellationError()
            }
            if let deadline, Date() >= deadline {
                timedOut = true
                terminateAndReap(process)
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Reap stragglers: handlers may lag process exit by a tick.
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        outBox.append(outHandle.availableData)
        errBox.append(errHandle.availableData)
        if let registration {
            processes.removeValue(forKey: registration)
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if timedOut {
            throw ProcessError.timedOut(seconds: timeout)
        }

        let stdout = String(data: outBox.take(), encoding: .utf8) ?? ""
        let stderr = String(data: errBox.take(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ProcessError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }
        return Result(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    /// Kill a registered process by ID. Best-effort; missing IDs are ignored.
    func terminate(registration: String?) async {
        guard let registration, let process = processes[registration] else { return }
        terminateAndReap(process)
        processes.removeValue(forKey: registration)
    }

    // MARK: - Private

    private func cleanup(handles: [FileHandle], registration: String?) {
        for handle in handles {
            handle.readabilityHandler = nil
        }
        if let registration {
            processes.removeValue(forKey: registration)
        }
    }

    /// SIGTERM, then SIGKILL if still alive after 3s. Called from the
    /// actor; the reap poll keeps it off-thread.
    private func terminateAndReap(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
    }

    /// Locate a backend binary. Phase 1: dev-machine PATH lookup.
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

/// Thread-safe byte accumulator for incremental pipe draining.
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum ProcessError: Error {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: TimeInterval)
}
