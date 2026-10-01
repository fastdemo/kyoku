import SwiftUI

/// Artists: list → artist detail (albums + tracks).
struct ArtistsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selected: Artist?
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Artists")
                .font(.largeTitle).fontWeight(.bold)
                .padding(20)
            Divider()
            if container.readyLibrary.artists.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(container.readyLibrary.artists) { artist in
                            artistCell(artist)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Artists")
        .sheet(item: $selected) { artist in
            ArtistDetailView(artist: artist)
                .environmentObject(container)
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    private func artistCell(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Circle().fill(Color(nsColor: .quaternaryLabelColor))
                Image(systemName: "music.mic")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 48))
            }
            .frame(width: 160, height: 160)
            .clipShape(Circle())
            Text(artist.name)
                .font(.headline)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = artist }
        .contextMenu {
            Button("Play All") {
                let all = container.readyLibrary.tracksForArtist(id: artist.id)
                if !all.isEmpty { container.player?.playTracks(all) }
            }
        }
        .accessibilityLabel("Artist \(artist.name)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.mic")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No artists yet")
                .font(.headline)
            Text("Artists appear automatically from downloaded music.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var container: AppContainer
    var artist: Artist
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let albums = container.readyLibrary.albumsForArtist(id: artist.id)
        let tracks = container.readyLibrary.tracksForArtist(id: artist.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name).font(.title).fontWeight(.bold)
                    Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play All") {
                    if !tracks.isEmpty { container.player?.playTracks(tracks) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
            }
            .padding(20)
            Divider()
            List {
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            Text(album.title)
                                .font(.headline)
                        }
                    }
                }
                Section("Songs") {
                    ForEach(tracks) { track in
                        TrackRow(track: track, context: tracks)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
