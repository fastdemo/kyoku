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
    /// Last playback failure for views to surface (missing/corrupt file).
    @Published private(set) var lastError: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Shuffle order: indices into `queue`. Rebuilt on shuffle toggle /
    /// queue change; `shufflePosition` tracks where we are in it.
    private var shuffleOrder: [Int] = []
    private var shufflePosition: Int?
    /// Whether the current track already counted as a play.
    private var countedPlayForTrackID: String?
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
        let removed = offsets.map { queue[$0].id }
        // Adjust current index before removal.
        if let currentIndex {
            let currentID = queue[currentIndex].id
            if removed.contains(currentID) {
                // Removing the playing track: advance first.
                next(auto: true)
            }
        }
        for index in offsets.sorted(by: >) {
            queue.remove(at: index)
        }
        if let currentIndex, let newIndex = queue.firstIndex(where: { $0.id == queue[currentIndex].id }) {
            self.currentIndex = newIndex
        } else if queue.isEmpty {
            stop()
            return
        }
        rebuildShuffleOrder()
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
        guard let player, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        currentTrack = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        state = .stopped
        countedPlayForTrackID = nil
    }

    // MARK: - Private

    /// Start playback at a queue index. Internal for production; exposed
    /// for tests (missing-file skip verification).
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        guard let path = track.localPath,
              FileManager.default.fileExists(atPath: path)
        else {
            // Missing file: surface + skip forward (never crash).
            lastError = "File not found: \(track.title)"
            logger.error("Missing file for track: \(track.title)")
            currentIndex = index
            currentTrack = track
            // Try the next track; stop if nothing playable remains.
            if let next = upcomingIndex(from: index) {
                play(at: next)
            } else {
                state = .stopped
            }
            return
        }
        lastError = nil
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        if player == nil {
            player = AVPlayer(playerItem: item)
            player?.volume = volume
        } else {
            player?.replaceCurrentItem(with: item)
        }
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.tick(time: time)
            }
        }
        // Duration: prefer the actual asset (what will play) over metadata.
        let seconds = CMTimeGetSeconds(item.asset.duration)
        duration = seconds.isFinite && seconds > 0 ? seconds : Double(track.duration)
        currentTime = 0
        currentIndex = index
        if isShuffled {
            // Keep position in sync when jumping (next/previous/test play).
            shufflePosition = shuffleOrder.firstIndex(of: index)
        }
        currentTrack = track
        countedPlayForTrackID = nil
        player?.play()
        state = .playing
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
        // Count short tracks that ended before the periodic observer fired.
        recordPlayIfEligible()
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
}

enum PlaybackState: Equatable, Sendable {
    case stopped
    case playing
    case paused
}
