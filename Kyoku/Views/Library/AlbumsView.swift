import SwiftUI

/// Albums: artwork-first grid → album detail (tracks).
struct AlbumsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selected: Album?
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Albums")
                .font(.largeTitle).fontWeight(.bold)
                .padding(20)
            Divider()
            if container.library.albums.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(container.library.albums) { album in
                            albumCell(album)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Albums")
        .sheet(item: $selected) { album in
            AlbumDetailView(album: album)
                .environmentObject(container)
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    private func albumCell(_ album: Album) -> some View {
        let tracks = container.library.tracksForAlbum(id: album.id)
        let art = tracks.first
        return VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artworkPath: album.artworkPath ?? art?.artworkPath,
                        coverURL: art?.coverURL, localPath: art?.localPath, size: 160)
            Text(album.title)
                .font(.headline)
                .lineLimit(1)
            Text(album.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click plays the album.
            let all = container.library.tracksForAlbum(id: album.id)
            if !all.isEmpty { container.player?.playTracks(all) }
        }
        .onTapGesture(count: 1) {
            selected = album
        }
        .contextMenu {
            Button("Play Album") {
                let all = container.library.tracksForAlbum(id: album.id)
                if !all.isEmpty { container.player?.playTracks(all) }
            }
            Button("Add to Queue") {
                for track in container.library.tracksForAlbum(id: album.id) {
                    container.player?.addToQueue(track)
                }
            }
        }
        .accessibilityLabel("Album \(album.title) by \(album.artist)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No albums yet")
                .font(.headline)
            Text("Albums appear automatically from downloaded music.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Album detail: header + ordered track list.
struct AlbumDetailView: View {
    @EnvironmentObject private var container: AppContainer
    var album: Album
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tracks = container.library.tracksForAlbum(id: album.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                ArtworkView(artworkPath: album.artworkPath ?? tracks.first?.artworkPath,
                            coverURL: tracks.first?.coverURL,
                            localPath: tracks.first?.localPath, size: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title).font(.title).fontWeight(.bold)
                    Text(album.artist).foregroundStyle(.secondary)
                    if tracks.count > 0 {
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Play") {
                    if !tracks.isEmpty { container.player?.playTracks(tracks) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
            }
            .padding(20)
            Divider()
            List(tracks) { track in
                TrackRow(track: track, context: tracks)
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
