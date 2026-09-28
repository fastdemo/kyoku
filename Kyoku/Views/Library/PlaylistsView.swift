import SwiftUI

/// Local playlists: sidebar list + ordered track detail with
/// create/rename/delete/add/remove/reorder. No sync in Phase 2.
struct PlaylistsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selectedID: String?
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var showingDelete: Playlist?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(container.library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Rename") {
                                renamingID = playlist.id
                                renameText = playlist.name
                            }
                            Button("Delete", role: .destructive) {
                                showingDelete = playlist
                            }
                        }
                }
                .onMove { source, dest in
                    // Sidebar order is alphabetical (DB ORDER BY name);
                    // track reorder happens in the detail list instead.
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Playlist")
            }
        } detail: {
            if let selectedID,
               let playlist = container.library.playlists.first(where: { $0.id == selectedID }) {
                PlaylistDetailView(playlist: playlist)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Select a playlist")
                        .font(.headline)
                    Text("Or create one with the + button.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Playlists")
        .alert("New Playlist", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let created = container.library.createPlaylist(name: newName)
                newName = ""
                selectedID = created.id
            }
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renamingID {
                    container.library.renamePlaylist(id: renamingID, name: renameText)
                }
                renamingID = nil
            }
        }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(
                get: { showingDelete != nil },
                set: { if !$0 { showingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                if let showingDelete {
                    container.library.deletePlaylist(id: showingDelete.id)
                    if selectedID == showingDelete.id { selectedID = nil }
                }
                showingDelete = nil
            }
            Button("Cancel", role: .cancel) { showingDelete = nil }
        } message: {
            // Playlists never own files: deleting removes the list only.
            Text("Only the playlist is removed. Tracks stay in your library.")
        }
    }
}

/// Ordered track list with drag reorder + play + remove.
struct PlaylistDetailView: View {
    @EnvironmentObject private var container: AppContainer
    var playlist: Playlist

    var body: some View {
        let tracks = container.library.playlistTracks(id: playlist.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name).font(.title).fontWeight(.bold)
                    Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play") {
                    if !tracks.isEmpty { container.player?.playTracks(tracks) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
            }
            .padding(20)
            Divider()
            if tracks.isEmpty {
                VStack(spacing: 8) {
                    Text("Empty playlist")
                        .font(.headline)
                    Text("Right-click a song anywhere to add it here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tracks) { track in
                        TrackRow(track: track, context: tracks)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    container.library.removeFromPlaylist(
                                        playlistID: playlist.id, trackID: track.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { source, dest in
                        var ids = tracks.map(\.id)
                        // Replicate SwiftUI move semantics on the ID array.
                        var moved: [String] = []
                        for index in source.sorted(by: >) {
                            moved.insert(ids.remove(at: index), at: 0)
                        }
                        var destIndex = dest
                        for index in source where index < dest { destIndex -= 1 }
                        ids.insert(contentsOf: moved, at: min(destIndex, ids.count))
                        container.library.reorderPlaylist(playlistID: playlist.id, orderedTrackIDs: ids)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
