import Foundation

/// First DownloadEngine implementation, backed by spotDL.
///
/// Pipeline (verified against spotdl 4.5.2 on the dev machine):
///   resolve:  `spotdl save QUERY --save-file - --preload`
///             → JSON array of Song records (metadata + candidate
///             download_url) on stdout.
///   download: `spotdl download SPOTIFY_URL --output DIR --format FMT ...`
///             → audio file with metadata/artwork embedded by spotDL.
///
/// Notes:
/// - Resolution is slow (1–7 min/query on first run: Spotify metadata +
///   per-track YouTube matching). Callers must treat it as long-running.
/// - `--preload` resolves the candidate audio URL during discovery; without
///   it, download_url is nil and matching happens at download time.
/// - `classifySource` is syntactic only; unknown input becomes a search term.
/// - Cancellation: Swift task cancellation kills the subprocess (see
///   ProcessRunner). spotdl installs a SIGINT handler for graceful exit,
///   so we use SIGTERM and also reap via a polling wait as fallback.
actor SpotDLEngine: DownloadEngine {
    private let runner: ProcessRunner
    private let logger = KyokuLogger(subsystem: "engine", category: "spotdl")
    private var running: [String: UUID] = [:]

    /// Timeout for `save` (discovery). Generous: cold runs take minutes.
    var resolveTimeout: TimeInterval = 600
    /// Timeout for one `download`. Generous for the same reason.
    var downloadTimeout: TimeInterval = 1200

    init(runner: ProcessRunner) {
        self.runner = runner
    }

    // MARK: - Availability

    /// Whether the spotdl binary is reachable (dev PATH or bundled Resources).
    func isAvailable() async -> Bool {
        (try? await spotdlBinary()) != nil
    }

    /// Backend version string for Settings display (nil when unavailable
    /// or when --version fails). Best-effort, short timeout — Settings
    /// must never hang on a broken backend.
    func backendVersion() async -> String? {
        guard let binary = try? await spotdlBinary() else { return nil }
        do {
            let result = try await runner.run(
                executable: binary, arguments: ["--version"],
                timeout: 15)
            let raw = (result.stdout + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            // spotdl --version prints like "4.5.0"; keep the first token.
            return raw.split(separator: "\n").first.map(String.init)
        } catch {
            return nil
        }
    }

    // MARK: - DownloadEngine

    func classifySource(_ input: String) -> SourceKind {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasSuffix(".spotdl") { return .spotdlFile }
        if q.contains("open.spotify.com") || q.hasPrefix("spotify:") {
            if q.contains("/playlist") || q.contains(":playlist:") { return .spotifyPlaylist }
            if q.contains("/album") || q.contains(":album:") { return .spotifyAlbum }
            if q.contains("/artist") || q.contains(":artist:") { return .spotifyArtist }
            return .spotifyTrack
        }
        if q.contains("music.youtube.com") { return .youTubeMusicLink }
        if q.contains("youtu.be") || q.contains("youtube.com") {
            if q.contains("list=") { return .youTubePlaylist }
            return .youTubeVideo
        }
        return .searchTerm
    }

    func resolveSource(_ url: String) async throws -> [DiscoveredTrack] {
        let query = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw DownloadEngineError.invalidInput("Enter a Spotify or YouTube URL, or a search term.")
        }
        let binary = try await spotdlBinary()
        let taskID = UUID().uuidString
        running[taskID] = UUID()

        // --preload resolves each track's candidate audio URL during
        // discovery. stdout carries the JSON array (--save-file -).
        let args = [
            "save", query,
            "--save-file", "-",
            "--preload",
        ]
        logger.info("Resolving: \(query)")
        defer { running.removeValue(forKey: taskID) }
        let result: ProcessRunner.Result
        do {
            result = try await runner.run(
                executable: binary,
                arguments: args,
                registration: taskID,
                timeout: resolveTimeout
            )
        } catch let error as ProcessError {
            throw mapProcessError(error, operation: "Discovery")
        }

        // spotdl logs to stderr; stdout should be pure JSON. Be strict:
        // find the JSON array, reject anything else.
        guard let jsonStart = result.stdout.firstIndex(of: "["),
              let jsonEnd = result.stdout.lastIndex(of: "]"),
              jsonStart < jsonEnd
        else {
            throw DownloadEngineError.parseFailed("no JSON array in spotdl output")
        }
        let jsonText = String(result.stdout[jsonStart ... jsonEnd])
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw DownloadEngineError.parseFailed("spotdl output is not UTF-8")
        }
        let songs: [ResolvedSong]
        do {
            songs = try JSONDecoder().decode([ResolvedSong].self, from: jsonData)
        } catch {
            throw DownloadEngineError.parseFailed(error.localizedDescription)
        }

        // Discovery can report songs with zero duration or empty names
        // (dead Spotify links). Drop them rather than queueing junk.
        let usable = songs.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.duration > 0 }
        if usable.count != songs.count {
            logger.info("Filtered \(songs.count - usable.count) unusable entries during discovery.")
        }
        return usable.map { DiscoveredTrack(song: $0, candidateURL: $0.downloadURL) }
    }

    func downloadTrack(
        _ song: ResolvedSong,
        profile: DownloadProfile,
        destination: URL
    ) async throws -> AsyncThrowingStream<DownloadProgress, Error> {
        let binary = try await spotdlBinary()
        // Registration contract with the queue: DownloadQueue sets
        // `registrationHint` to its DownloadTask.id before calling, so
        // cancel(taskID:) can terminate THIS subprocess via
        // ProcessRunner.terminate(registration:). Falls back to a UUID
        // when the engine is used standalone (tests, previews).
        let registration = registrationHint ?? UUID().uuidString
        registrationHint = nil
        running[registration] = UUID()

        return AsyncThrowingStream { continuation in
            Task {
                var args = [
                    "download", song.url,
                    "--output", destination.path,
                    "--format", profile.format.spotdlName,
                    "--bitrate", profile.bitrateFlag,
                ]
                if !profile.embedLyrics {
                    args += ["--lyrics", "none"]
                }
                // Metadata/artwork embedding is on by default in spotDL;
                // --overwrite skip avoids re-downloading existing files.
                args += ["--overwrite", "skip"]

                continuation.yield(.matching("Downloading \(song.artist) – \(song.name)"))
                do {
                    let result = try await self.runner.run(
                        executable: binary,
                        arguments: args,
                        registration: registration,
                        timeout: self.downloadTimeout
                    ) { line in
                        if line.contains("Downloaded") {
                            continuation.yield(.downloading(fraction: nil))
                        } else if line.contains("Embedding") || line.contains("metadata") {
                            continuation.yield(.processing(line))
                        }
                    }
                    // spotdl names files "{artist} - {title}.{ext}".
                    // Prefer the actual file if present; fall back to the
                    // conventional name.
                    if let file = self.findOutput(for: song, profile: profile, in: destination) {
                        continuation.yield(.completed(file))
                    } else {
                        throw DownloadEngineError.backendFailed(
                            exitCode: result.exitCode,
                            message: "spotdl finished but no audio file was found in \(destination.path)"
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
                self.running.removeValue(forKey: registration)
            }
        }
    }

    /// Set by DownloadQueue before downloadTrack so cancel(taskID:) maps
    /// to the live subprocess. Actor-isolated: queue and engine hop
    /// through the actor, so no race.
    var registrationHint: String?

    func setRegistrationHint(_ id: String?) async { registrationHint = id }

    func cancel(taskID: String) async {
        // Real cancellation: terminate the backend subprocess by its
        // registration ID. The runner's poll loop observes the kill;
        // the queue's cancel flag guarantees .cancelled state even if
        // the backend surfaces a non-zero exit instead of CancellationError.
        await runner.terminate(registration: taskID)
        running.removeValue(forKey: taskID)
        logger.info("Cancel requested: \(taskID)")
    }

    // MARK: - Private

    private func spotdlBinary() async throws -> URL {
        if let bundled = bundledBinary() { return bundled }
        // Dev-machine PATH lookup (python.org installs land outside
        // Homebrew prefixes, so check there explicitly).
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/spotdl",
            "/opt/homebrew/bin/spotdl",
            "/usr/local/bin/spotdl",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let found = runner.locate("spotdl") { return found }
        throw DownloadEngineError.backendMissing
    }

    private nonisolated func bundledBinary() -> URL? {
        Bundle.main.url(forResource: "spotdl", withExtension: nil, subdirectory: "Backend")
    }

    private func mapProcessError(_ error: ProcessError, operation: String) -> DownloadEngineError {
        switch error {
        case .launchFailed(let detail):
            return .backendFailed(exitCode: -1, message: String(detail.prefix(300)))
        case .nonZeroExit(let code, let stderr):
            let message = stderr.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map(String.init) ?? "exit code \(code)"
            return .backendFailed(exitCode: code, message: String(message.prefix(300)))
        case .timedOut(let seconds):
            return .timedOut(operation: "\(operation) (\(Int(seconds))s)")
        }
    }

    /// Locate spotDL's output file. Prefers a fresh audio file in the
    /// destination over the conventional "{artist} - {title}.{ext}" name,
    /// which breaks on unusual characters.
    private nonisolated func findOutput(
        for song: ResolvedSong,
        profile: DownloadProfile,
        in destination: URL
    ) -> URL? {
        let fm = FileManager.default
        let exts = [profile.format.fileExtension, "mp3", "m4a", "opus", "flac", "ogg", "wav"]
        let conventional = destination
            .appendingPathComponent("\(song.artist) - \(song.name)")
            .appendingPathExtension(profile.format.fileExtension)
        if fm.fileExists(atPath: conventional.path) { return conventional }

        guard let files = try? fm.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                (modificationDate(a) ?? .distantPast) > (modificationDate(b) ?? .distantPast)
            }
            .first
    }
}

private func modificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

private extension DownloadProfile.AudioFormat {
    /// spotDL --format names. m4a/opus pass through; flac/mp3 likewise.
    var spotdlName: String {
        switch self {
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .flac: return "flac"
        case .opus: return "opus"
        }
    }

    var fileExtension: String { spotdlName }
}

private extension DownloadProfile {
    /// spotDL --bitrate flag. Lossless formats ignore bitrate; mp3/m4a
    /// default to a transparent-ish 256k. Tunable per-profile in Phase 5.
    var bitrateFlag: String {
        switch format {
        case .flac: return "disable"
        case .opus: return "128k"
        case .mp3, .m4a: return "256k"
        }
    }
}
