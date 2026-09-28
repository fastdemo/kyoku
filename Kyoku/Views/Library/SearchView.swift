import SwiftUI

/// Global search: DB-backed LIKE queries per section (no giant
/// in-memory filter). Sections for songs, albums, artists, playlists.
struct SearchView: View {
    @EnvironmentObject private var container: AppContainer
    var query: String

    var body: some View {
        let results = container.library.search(query)
        VStack(alignment: .leading, spacing: 0) {
            Text("Results for “\(query)”")
                .font(.title2).fontWeight(.semibold)
                .padding(20)
            Divider()
            if results.tracks.isEmpty && results.albums.isEmpty
                && results.artists.isEmpty && results.playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.headline)
                    Text("Try a different search.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !results.tracks.isEmpty {
                        Section("Songs") {
                            ForEach(results.tracks) { track in
                                TrackRow(track: track, context: results.tracks)
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        Section("Albums") {
                            ForEach(results.albums) { album in
                                HStack(spacing: 10) {
                                    let art = container.library.tracksForAlbum(id: album.id).first
                                    ArtworkView(artworkPath: album.artworkPath,
                                                coverURL: art?.coverURL,
                                                localPath: art?.localPath, size: 40)
                                    VStack(alignment: .leading) {
                                        Text(album.title).lineLimit(1)
                                        Text(album.artist)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    if !results.artists.isEmpty {
                        Section("Artists") {
                            ForEach(results.artists) { artist in
                                Label(artist.name, systemImage: "music.mic")
                            }
                        }
                    }
                    if !results.playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(results.playlists) { playlist in
                                Label(playlist.name, systemImage: "music.note.list")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Search")
    }
}
