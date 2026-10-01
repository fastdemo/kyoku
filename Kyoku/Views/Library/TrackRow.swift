import SwiftUI

/// Single track row: artwork, title/artist, album, duration.
/// Double-click plays; context menu for everything else.
struct TrackRow: View {
    @EnvironmentObject private var container: AppContainer
    var track: Track
    var context: [Track] = []
    var showArtwork: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            if showArtwork {
                ArtworkView(artworkPath: track.artworkPath, coverURL: track.coverURL,
                            localPath: track.localPath, size: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(track.isAvailable ? .primary : .secondary)
                    if !track.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("File unavailable — the audio file is missing from disk. Metadata is preserved.")
                            .accessibilityLabel("File missing")
                    }
                }
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.album)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)
            Text(formatDuration(track.duration))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            container.player?.play(track, in: context.isEmpty ? nil : context)
        }
        .trackMenu(track: track, context: context)
        .accessibilityLabel("\(track.title) by \(track.artist)")
        .accessibilityHint("Double-click to play")
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
