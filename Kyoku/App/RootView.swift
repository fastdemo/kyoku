import SwiftUI

/// Phase 2 root: sidebar navigation + persistent bottom player.
/// Detail views are thin; all state lives in LibraryStore/PlaybackService.
struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selection: NavItem? = .recentlyAdded
    @State private var searchText = ""
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Listen") {
                    Label("Recently Added", systemImage: "clock").tag(NavItem.recentlyAdded)
                    Label("Recently Played", systemImage: "memories").tag(NavItem.recentlyPlayed)
                }
                Section("Library") {
                    Label("Songs", systemImage: "music.note").tag(NavItem.songs)
                    Label("Albums", systemImage: "square.stack").tag(NavItem.albums)
                    Label("Artists", systemImage: "music.mic").tag(NavItem.artists)
                }
                Section("Playlists") {
                    Label("Playlists", systemImage: "music.note.list").tag(NavItem.playlists)
                }
                Section("Downloads") {
                    Label("Queue", systemImage: "arrow.down.circle").tag(NavItem.queue)
                }
                Section("Automation") {
                    Label("Sources", systemImage: "antenna.radiowaves.left.and.right").tag(NavItem.sources)
                }
            }
            .navigationTitle("Kyoku")
        } detail: {
            VStack(spacing: 0) {
                detailView
                IfPlayer { player in
                    Divider()
                    PlayerBar(player: player, showingNowPlaying: $showingNowPlaying)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search songs, albums, artists, playlists")
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showingNowPlaying) {
            IfPlayer { player in
                NowPlayingView(player: player)
                    .frame(minWidth: 560, minHeight: 620)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchView(query: searchText)
        } else {
            switch selection ?? .recentlyAdded {
            case .recentlyAdded:
                RecentlyAddedView()
            case .recentlyPlayed:
                RecentlyPlayedView()
            case .songs:
                SongsView()
            case .albums:
                AlbumsView()
            case .artists:
                ArtistsView()
            case .playlists:
                PlaylistsView()
            case .queue:
                QueueView()
            case .sources:
                SourcesView()
            }
        }
    }
}

enum NavItem: Hashable {
    case recentlyAdded
    case recentlyPlayed
    case songs
    case albums
    case artists
    case playlists
    case queue
    case sources
}
