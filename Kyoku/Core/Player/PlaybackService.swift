import AVFoundation
import Combine
import Foundation

/// Native local playback. Owns AVPlayer, playback queue, time/duration,
/// volume, shuffle/repeat, history recording, and missing-file skipping.
/// Views observe published state; they never touch AVPlayer directly.
///
/// Play-count rule: a play counts only after min(30s, 50% of duration)
/// of actual playback, so skips and accidental clicks don't inflate
/// history. Documented here and in recordPlayIfEligible.
@MainActor
final class PlaybackService: ObservableObject {
    enum RepeatMode: String, Sendable, CaseIterable {
        case off, all, one
    }

    @Published private(set) var state: PlaybackState = .stopped
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published var volume: Float = 1.0 { didSet { player?.volume = volume } }
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    /// Typed last failure for views to surface (nil = no error).
    @Published private(set) var playbackError: PlaybackError?
    /// String convenience for existing views (mirrors playbackError).
    var lastError: String? { playbackError?.displayMessage }
    /// Whether duration came from the item (true) or is still metadata-only.
    @Published private(set) var durationIsLoaded = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    /// App-lifetime end-of-track observer (DidPlayToEndTime, any item;
    /// trackDidFinish verifies identity). Removed in deinit.
    private var endObserver: NSObjectProtocol?
    /// Per-item failure observer (FailedToPlayToEndTime on the CURRENT
    /// item only). Reinstalled on every play(at:); removed in stop() and
    /// whenever the item is replaced. The app-lifetime end-of-track
    /// observer is separate (see init) and removed in deinit.
    private var failureObserver: NSObjectProtocol?
    /// Shuffle order: indices into `queue`. Rebuilt on shuffle toggle /
    /// queue change; `shufflePosition` tracks where we are in it.
    private var shuffleOrder: [Int] = []
    private var shufflePosition: Int?
    /// Whether the current track already counted as a play.
    private var countedPlayForTrackID: String?
    /// Seek requested while duration was unavailable; applied once the
    /// item reports a usable duration. Cleared on track change / failure.
    private var pendingSeek: Double?
    private let logger = KyokuLogger(subsystem: "core", category: "playback")

    /// Library callback for history. Set by AppContainer (avoids a
    /// LibraryStore dependency inside the player).
    var onRecordPlay: ((String) -> Void)?

    init() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.trackDidFinish(note.object as? AVPlayerItem)
            }
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Queue management (playback queue, NOT the download queue)

    /// Replace the queue and start at `index`.
    func playTracks(_ tracks: [Track], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        let start = tracks.indices.contains(index) ? index : 0
        currentIndex = start
        if isShuffled {
            // New queue: reshuffle but keep the starting track first so
            // playback begins there, then continues through the rest.
            shuffleOrder = [start] + queue.indices.filter { $0 != start }.shuffled()
            shufflePosition = 0
        } else {
            shuffleOrder = []
            shufflePosition = nil
        }
        play(at: start)
    }

    func play(_ track: Track, in context: [Track]? = nil) {
        if let context, let index = context.firstIndex(where: { $0.id == track.id }) {
            playTracks(context, startingAt: index)
        } else {
            playTracks([track], startingAt: 0)
        }
    }

    func playNext(_ track: Track) {
        if let currentIndex {
            queue.insert(track, at: currentIndex + 1)
            // Keep the new track next in shuffle order too.
            if isShuffled {
                shuffleOrder = shuffleOrder.map { $0 > currentIndex ? $0 + 1 : $0 }
                if let pos = shufflePosition {
                    shuffleOrder.insert(currentIndex + 1, at: pos + 1)
                }
            }
        } else {
            queue.insert(track, at: 0)
            rebuildShuffleOrder()
        }
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if isShuffled {
            shuffleOrder.append(queue.count - 1)
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Snapshot the playing track's identity first: every mutation
        // below is expressed in terms of IDs, never stale indices.
        let playingID = currentIndex.map { queue[$0].id }
        let removedIDs = Set(offsets.map { queue[$0].id })
        let playingRemoved = playingID.map { removedIDs.contains($0) } ?? false

        // Remove high-to-low so earlier indices stay valid.
        for index in offsets.sorted(by: >) {
            queue.remove(at: index)
        }
        guard !queue.isEmpty else {
            stop()
            return
        }
        if playingRemoved {
            // The playing track is gone: continue from the track that slid
            // into the lowest removed position (or the new tail), and keep
            // playing. Clamp: removing the tail means "next" is the new tail.
            let resume = min(offsets.min() ?? 0, queue.count - 1)
            currentIndex = resume
            play(at: resume)
        } else if let playingID,
                  let newIndex = queue.firstIndex(where: { $0.id == playingID }) {
            currentIndex = newIndex
            if isShuffled {
                shufflePosition = shuffleOrder.firstIndex(of: newIndex)
            }
        }
        if isShuffled {
            // Indices shifted: rebuild order around the surviving position.
            // Preserve remaining shuffle order for unplayed tracks where
            // possible is overkill; a clean rebuild anchored at current is
            // predictable and test-covered.
            if let currentIndex {
                shuffleOrder = [currentIndex] + queue.indices.filter { $0 != currentIndex }.shuffled()
                shufflePosition = 0
            } else {
                rebuildShuffleOrder()
            }
        }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        var reordered = queue
        // Map current track ID so the index survives the move.
        let currentID = currentIndex.map { queue[$0].id }
        var dest = destination
        for index in source.sorted(by: >) {
            let item = reordered.remove(at: index)
            if index < dest { dest -= 1 }
            reordered.insert(item, at: min(dest, reordered.count))
        }
        queue = reordered
        if let currentID {
            currentIndex = queue.firstIndex(where: { $0.id == currentID })
        }
        rebuildShuffleOrder()
    }

    func clearQueue() {
        stop()
        queue = []
        shuffleOrder = []
        shufflePosition = nil
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled, let currentIndex {
            // Keep the current track first, shuffle the rest behind it.
            shuffleOrder = [currentIndex] + queue.indices.filter { $0 != currentIndex }.shuffled()
            shufflePosition = 0
        } else {
            shuffleOrder = []
            shufflePosition = nil
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        switch state {
        case .playing:
            player?.pause()
            state = .paused
        case .paused:
            player?.play()
            state = .playing
        case .stopped:
            if currentTrack != nil { player?.play(); state = .playing }
        }
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, auto, currentIndex != nil {
            seek(to: 0)
            player?.play()
            state = .playing
            return
        }
        if let nextIndex = upcomingIndex() {
            play(at: nextIndex)
        } else if !auto {
            // Manual next at end with repeat-all wraps.
            if repeatMode == .all, let first = firstIndex() {
                play(at: first)
            }
        } else {
            // Auto-advance at end: stop unless repeat-all.
            if repeatMode == .all, let first = firstIndex() {
                play(at: first)
            } else {
                state = .stopped
            }
        }
    }

    func previous() {
        // Standard behavior: restart when >3s in, else go back.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        if isShuffled {
            guard let pos = shufflePosition else { return }
            if pos > 0 {
                shufflePosition = pos - 1
                play(at: shuffleOrder[pos - 1])
            } else {
                seek(to: 0)
            }
        } else if let currentIndex, currentIndex > 0 {
            play(at: currentIndex - 1)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        guard let player else {
            playbackError = .seekUnavailable
            return
        }
        guard durationIsLoaded, duration > 0 else {
            // Duration not ready: retain and apply when the item loads.
            // Clamped against the real duration then (never silently drop).
            pendingSeek = seconds
            return
        }
        let clamped = min(max(0, seconds), duration)
        pendingSeek = nil
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        removeFailureObserver()
        currentTrack = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        durationIsLoaded = false
        pendingSeek = nil
        state = .stopped
        countedPlayForTrackID = nil
    }

    // MARK: - Private

    /// Start playback at a queue index. Internal for production; exposed
    /// for tests (missing-file skip verification).
    ///
    /// Missing/unplayable tracks are skipped ITERATIVELY (loop, never
    /// recursion): consecutive failures advance through the queue safely,
    /// and an all-missing tail ends stopped with an honest error — never
    /// a stuck `.playing`, never stack growth.
    func play(at index: Int) {
        var candidate: Int? = index
        var lastFailure: PlaybackError?
        while let current = candidate, queue.indices.contains(current) {
            let track = queue[current]
            guard let path = track.localPath,
                  FileManager.default.fileExists(atPath: path)
            else {
                lastFailure = .fileUnavailable(trackTitle: track.title)
                logger.error("Missing file for track: \(track.title)")
                currentIndex = current
                currentTrack = track
                countedPlayForTrackID = nil
                candidate = upcomingIndex(from: current)
                continue
            }
            startItem(for: track, at: current)
            // startItem either begins honest playback or records a failure
            // and returns false (item already failed synchronously).
            if state == .playing || state == .paused {
                return
            }
            lastFailure = playbackError
            candidate = upcomingIndex(from: current)
        }
        // Nothing playable remains: coherent stopped state + last error.
        playbackError = lastFailure
        currentTime = 0
        duration = 0
        durationIsLoaded = false
        state = .stopped
    }

    /// Begin playback of a verified-present file. Returns via state:
    /// `.playing` on success; on synchronous item failure records
    /// playbackError and leaves state alone for the caller to advance.
    private func startItem(for track: Track, at index: Int) {
        playbackError = nil
        pendingSeek = nil
        durationIsLoaded = false
        trackLoadGeneration += 1
        let item = AVPlayerItem(url: URL(fileURLWithPath: track.localPath!))
        if player == nil {
            player = AVPlayer(playerItem: item)
            player?.volume = volume
        } else {
            player?.replaceCurrentItem(with: item)
        }
        removeTimeObserver()
        removeFailureObserver()
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.itemDidFail(note.object as? AVPlayerItem)
            }
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.tick(time: time)
            }
        }
        // Synchronous failure check: some corrupt files fail immediately.
        if item.status == .failed {
            itemDidFail(item)
            return
        }
        // Duration: metadata immediately (honest placeholder), real value
        // async. Never blocks; pending seeks apply when it lands.
        duration = Double(track.duration)
        currentTime = 0
        currentIndex = index
        if isShuffled {
            // Keep position in sync when jumping (next/previous/test play).
            shufflePosition = shuffleOrder.firstIndex(of: index)
        }
        currentTrack = track
        countedPlayForTrackID = nil
        // Observe readiness: corrupt files surface .failed asynchronously
        // (status starts .unknown and may take seconds). Poll cheaply until
        // ready-or-failed; on failure advance honestly. The poll is bounded
        // (60 ticks) and cancelled implicitly by track change (generation).
        let generation = trackLoadGeneration
        observeItemReadiness(item, trackID: track.id, generation: generation)
        loadDurationAsync(for: item, trackID: track.id)
        player?.play()
        state = .playing
    }

    /// Monotonic track-load generation: readiness polls from a superseded
    /// load exit silently when a new track starts.
    private var trackLoadGeneration = 0

    private func observeItemReadiness(_ item: AVPlayerItem, trackID: String, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                // Superseded (new track started) or already handled: exit.
                guard self.trackLoadGeneration == generation,
                      self.currentTrack?.id == trackID
                else { return }
                if item.status == .failed {
                    self.itemDidFail(item)
                    return
                }
                if item.status == .readyToPlay { return }
            }
            // Still unknown after 15s: leave playing (backend may recover);
            // the failure observer catches terminal errors when they arrive.
        }
    }

    /// Resolve the real duration off the item without blocking. Applies
    /// any pending seek, then marks duration loaded. Failures leave the
    /// metadata fallback in place (never zero the progress bar).
    private func loadDurationAsync(for item: AVPlayerItem, trackID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var resolved: Double?
            if #available(macOS 13, *) {
                do {
                    let d = try await item.asset.load(.duration)
                    let seconds = CMTimeGetSeconds(d)
                    if seconds.isFinite, seconds > 0 { resolved = seconds }
                } catch {
                    // Keep metadata fallback; not a playback failure.
                }
            } else {
                let seconds = CMTimeGetSeconds(item.asset.duration)
                if seconds.isFinite, seconds > 0 { resolved = seconds }
            }
            // Stale load (track changed while awaiting)? Ignore.
            guard self.currentTrack?.id == trackID else { return }
            if let resolved {
                self.duration = resolved
                self.durationIsLoaded = true
                if let pending = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: pending)
                }
            }
        }
    }

    /// AVPlayerItem failed (status .failed now, or FailedToPlayToEndTime
    /// later). Records a typed error, clears play-count arming (a failure
    /// must never count as a play), and advances to the next playable
    /// track — or stops honestly when none remains.
    private func itemDidFail(_ item: AVPlayerItem?) {
        if let current = player?.currentItem, let item, current !== item { return }
        guard let track = currentTrack else { return }
        let underlying = (item?.error ?? player?.currentItem?.error)?.localizedDescription
        playbackError = .undecodable(trackTitle: track.title, underlying: underlying)
        logger.error("Unplayable track: \(track.title) (\(underlying ?? "unknown"))")
        countedPlayForTrackID = nil
        player?.pause()
        if let currentIndex, let next = upcomingIndex(from: currentIndex) {
            play(at: next)
        } else {
            currentTime = 0
            duration = 0
            durationIsLoaded = false
            state = .stopped
        }
    }

    private func tick(time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        currentTime = seconds
        recordPlayIfEligible()
    }

    /// Meaningful-play rule: min(30s, 50% of duration). Fires once per
    /// track load; repeats of the same track (repeat-one) re-arm via
    /// play(at:) resetting countedPlayForTrackID.
    private func recordPlayIfEligible() {
        guard let track = currentTrack,
              countedPlayForTrackID != track.id,
              duration > 0
        else { return }
        let threshold = min(30, duration * 0.5)
        if currentTime >= threshold {
            countedPlayForTrackID = track.id
            onRecordPlay?(track.id)
        }
    }

    private func trackDidFinish(_ item: AVPlayerItem?) {
        // Only respond to our own item finishing.
        if let current = player?.currentItem, let item, current !== item { return }
        // A finished track was necessarily listened through: count it
        // unconditionally (the threshold only gates mid-playback ticks).
        if let track = currentTrack, countedPlayForTrackID != track.id {
            countedPlayForTrackID = track.id
            onRecordPlay?(track.id)
        }
        next(auto: true)
    }

    /// Next index in play order (shuffle-aware), nil at the end.
    private func upcomingIndex(from index: Int? = nil) -> Int? {
        let base = index ?? currentIndex
        if isShuffled {
            guard let pos = (index.map { shuffleOrder.firstIndex(of: $0) } ?? shufflePosition) else { return nil }
            let next = pos + 1
            return next < shuffleOrder.count ? shuffleOrder[next] : nil
        } else {
            guard let base else { return queue.isEmpty ? nil : 0 }
            let next = base + 1
            return next < queue.count ? next : nil
        }
    }

    private func firstIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if isShuffled, let first = shuffleOrder.first { return first }
        return 0
    }

    private func rebuildShuffleOrder() {
        shuffleOrder = queue.indices.shuffled()
        if let currentIndex, isShuffled {
            shufflePosition = shuffleOrder.firstIndex(of: currentIndex)
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func removeFailureObserver() {
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

#if DEBUG
    // MARK: - Test hooks

    /// Simulate the periodic time observer firing (threshold path).
    func simulateTimeForTests(seconds: Double) {
        tick(time: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Simulate the end-of-track notification (finish path).
    func simulateFinishForTests() {
        trackDidFinish(player?.currentItem)
    }

    /// Simulate FailedToPlayToEndTime on the current item.
    func simulateItemFailureForTests() {
        itemDidFail(player?.currentItem)
    }
#endif
}

enum PlaybackState: Equatable, Sendable {
    case stopped
    case playing
    case paused
}
