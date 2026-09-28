import SwiftUI

/// Now Playing: large artwork, metadata, progress, transport, queue peek.
/// Minimalist sheet, not an Apple Music clone.
struct NowPlayingView: View {
    @ObservedObject var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            ArtworkView(artworkPath: player.currentTrack?.artworkPath,
                        coverURL: player.currentTrack?.coverURL,
                        localPath: player.currentTrack?.localPath, size: 280)
            VStack(spacing: 4) {
                Text(player.currentTrack?.title ?? "—")
                    .font(.title2).fontWeight(.semibold)
                Text(player.currentTrack?.artist ?? "—")
                    .font(.title3).foregroundStyle(.secondary)
                Text(player.currentTrack?.album ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
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
                HStack {
                    Text(formatTime(isSeeking ? seekValue : player.currentTime))
                    Spacer()
                    Text(formatTime(player.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            HStack(spacing: 24) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(player.isShuffled ? .blue : .secondary)
                }
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundColor(player.repeatMode == .off ? .secondary : .blue)
                }
            }
            .buttonStyle(.plain)
            .font(.title2)
            if let error = player.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
