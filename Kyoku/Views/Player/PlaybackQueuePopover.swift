import SwiftUI

/// Playback queue inspector: ordered upcoming tracks with reorder,
/// remove, clear, play-next semantics. Separate from Downloads Queue.
struct PlaybackQueuePopover: View {
    @ObservedObject var player: PlaybackService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(.headline)
                Spacer()
                if !player.queue.isEmpty {
                    Button("Clear") { player.clearQueue() }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            Divider()
            if player.queue.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                    Text("Queue is empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 8) {
                            if index == player.currentIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)
                            } else {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 20)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            player.play(at: index)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                player.removeFromQueue(at: IndexSet(integer: index))
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, dest in
                        player.moveInQueue(from: source, to: dest)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
