import AVFoundation
import Combine
import Foundation

/// Playback state machine. Phase 0: local-file playback via AVPlayer.
/// Queue/shuffle/repeat/history arrive in Phase 2.
final class PlayerService: ObservableObject {
    enum State: Equatable {
        case stopped
        case playing
        case paused
    }

    @Published private(set) var state: State = .stopped
    @Published var currentTrack: Track?
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    private var player: AVPlayer?
    private let logger = KyokuLogger(subsystem: "core", category: "player")

    func play(_ track: Track) {
        guard let path = track.localPath else {
            logger.error("No local file for track: \(track.title)")
            return
        }
        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.volume = volume
        player?.play()
        currentTrack = track
        state = .playing
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            player?.pause()
            state = .paused
        case .paused:
            player?.play()
            state = .playing
        case .stopped:
            break
        }
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        currentTrack = nil
        state = .stopped
    }
}
