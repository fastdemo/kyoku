import SwiftUI

/// Persistent bottom player bar: artwork, title/artist, transport,
/// progress, volume, shuffle/repeat, queue access. Thin observer over
/// PlaybackService; takes the service non-optional (gated by IfPlayer).
struct PlayerBar: View {
    @ObservedObject var player: PlaybackService
    @Binding var showingNowPlaying: Bool
    @State private var showingQueue = false
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            // Artwork + titles (click opens Now Playing).
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(artworkPath: player.currentTrack?.artworkPath,
                                coverURL: player.currentTrack?.coverURL,
                                localPath: player.currentTrack?.localPath, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.currentTrack?.title ?? "—")
                            .font(.headline)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help("Open Now Playing")

            // Transport.
            HStack(spacing: 4) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(player.isShuffled ? .blue : .secondary)
                }
                .help("Shuffle")
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous")
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36)
                }
                .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next")
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: repeatIcon)
                        .foregroundColor(player.repeatMode == .off ? .secondary : .blue)
                }
                .help("Repeat: \(player.repeatMode.rawValue)")
            }
            .buttonStyle(.plain)
            .font(.title3)

            // Progress.
            Text(formatTime(displayTime))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Slider(value: Binding(
                get: { isSeeking ? seekValue : player.currentTime },
                set: { seekValue = $0 }
            ), in: 0 ... max(player.duration, 1)) { editing in
                if editing {
                    isSeeking = true
                } else if isSeeking {
                    player.seek(to: seekValue)
                    isSeeking = false
                }
            }
            Text(formatTime(player.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44)

            // Volume + queue.
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Slider(value: Binding(
                get: { Double(player.volume) },
                set: { player.volume = Float($0) }
            ), in: 0 ... 1)
            .frame(width: 90)
            Button {
                showingQueue = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("Playback Queue")
            .buttonStyle(.plain)
            .popover(isPresented: $showingQueue) {
                PlaybackQueuePopover(player: player)
                    .frame(width: 340, height: 400)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var displayTime: Double {
        isSeeking ? seekValue : player.currentTime
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
