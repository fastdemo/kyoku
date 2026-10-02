import SwiftUI

/// App root: sidebar navigation + persistent bottom player.
/// Detail views are thin; all state lives in LibraryStore/PlaybackService.
///
/// Sidebar model (product hierarchy): the music library (Songs/Albums/
/// Artists) and Playlists are the primary experience; Downloads and
/// Automation (Sources, Sync Jobs + Activity/Needs Attention) are
/// operational tools. No permanent Recently Added/Played destinations —
/// recency belongs to the Home overview, not sidebar navigation.
struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selection: NavItem? = .home
    @State private var searchText = ""
    @State private var showingNowPlaying = false
    @State private var showingAddPlaylist = false
    @State private var renameTarget: Playlist?
    @State private var renameText = ""
    @State private var deleteTarget: Playlist?
    @State private var syncJobsExpanded = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section("Library") {
                    Label("Home", systemImage: "house").tag(NavItem.home)
                    Label("Songs", systemImage: "music.note").tag(NavItem.songs)
                    Label("Albums", systemImage: "square.stack").tag(NavItem.albums)
                    Label("Artists", systemImage: "music.mic").tag(NavItem.artists)
                }
                Section("Playlists") {
                    ForEach(container.readyLibrary.playlists) { playlist in
                        Label(playlist.name, systemImage: "music.note.list")
                            .tag(NavItem.playlist(id: playlist.id))
                            .contextMenu {
                                Button("Rename") { renameTarget = playlist; renameText = playlist.name }
                                Button("Delete", role: .destructive) { deleteTarget = playlist }
                            }
                    }
                    Button {
                        showingAddPlaylist = true
                    } label: {
                        Label("Add Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Section("Downloads") {
                    Label("Queue", systemImage: "arrow.down.circle").tag(NavItem.queue)
                }
                Section("Automation") {
                    Label("Sources", systemImage: "antenna.radiowaves.left.and.right").tag(NavItem.sources)
                    DisclosureGroup("Sync Jobs", isExpanded: $syncJobsExpanded) {
                        Button("All Jobs") { selection = .syncJobs }
                            .buttonStyle(.plain)
                            .foregroundStyle(selection == .syncJobs ? .primary : .secondary)
                        Button("Activity") { selection = .activity }
                            .buttonStyle(.plain)
                            .foregroundStyle(selection == .activity ? .primary : .secondary)
                        Button("Needs Attention") { selection = .attention }
                            .buttonStyle(.plain)
                            .foregroundStyle(selection == .attention ? .primary : .secondary)
                    }
                }
            }
            .navigationTitle("Kyoku")
            // Default sidebar width must fit the longest labels
            // ("Needs Attention", playlist names) without truncation
            // on first launch.
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
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
        .sheet(isPresented: $showingAddPlaylist) {
            addPlaylistSheet
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameTarget {
                    container.readyLibrary.renamePlaylist(id: renameTarget.id, name: renameText)
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                if let deleteTarget {
                    container.readyLibrary.deletePlaylist(id: deleteTarget.id)
                    if selection == .playlist(id: deleteTarget.id) { selection = .home }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            // Playlists never own files: deleting removes the list only.
            Text("Only the playlist is removed. Tracks stay in your library.")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchView(query: searchText)
        } else {
            switch selection ?? .home {
            case .home:
                HomeView(
                    select: { selection = $0 },
                    openPlaylist: { selection = .playlist(id: $0) })
            case .songs:
                SongsView()
            case .albums:
                AlbumsView()
            case .artists:
                ArtistsView()
            case .playlist(let id):
                PlaylistDetailStandalone(playlistID: id)
            case .queue:
                QueueView()
            case .sources:
                SourcesView()
            case .syncJobs:
                SyncJobsView()
            case .activity:
                ActivityView()
            case .attention:
                NeedsAttentionView()
            }
        }
    }

    // MARK: - Add Playlist (URL-first workflow)

    /// Paste a Spotify/YouTube playlist URL → resolve → preview with
    /// artwork + metadata → confirm → source + snapshot + sync job with a
    /// sensible default (destination <Music>/<Playlist Name>/, manual
    /// schedule, ask-policy removals) → enqueue downloads. The user never
    /// sees Source/SyncJob/snapshot objects; power users can inspect them
    /// under Automation afterwards.
    private var addPlaylistSheet: some View {
        AddPlaylistView { playlistID in
            selection = .playlist(id: playlistID)
        }
        .environmentObject(container)
        .frame(minWidth: 560, minHeight: 520)
    }
}

/// Standalone playlist detail for sidebar-direct selection (owns its own
/// playlist lookup; the embedded PlaylistsView keeps its nested split for
/// in-place management).
private struct PlaylistDetailStandalone: View {
    @EnvironmentObject private var container: AppContainer
    var playlistID: String

    var body: some View {
        if let playlist = container.readyLibrary.playlists.first(where: { $0.id == playlistID }) {
            PlaylistDetailView(playlist: playlist)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("Playlist removed")
                    .font(.headline)
                Text("It may have been deleted. Choose another playlist.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum NavItem: Hashable {
    case home
    case songs
    case albums
    case artists
    case playlist(id: String)
    case queue
    case sources
    case syncJobs
    case activity
    case attention
}
