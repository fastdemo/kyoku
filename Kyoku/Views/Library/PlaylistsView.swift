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
                ForEach(container.readyLibrary.playlists) { playlist in
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
               let playlist = container.readyLibrary.playlists.first(where: { $0.id == selectedID }) {
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
                let created = container.readyLibrary.createPlaylist(name: newName)
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
                    container.readyLibrary.renamePlaylist(id: renamingID, name: renameText)
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
                    container.readyLibrary.deletePlaylist(id: showingDelete.id)
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

/// Playlist detail: Apple Music-style header (large artwork, title,
/// source, counts, transport + sync status) over a clean track table.
/// Used standalone from the sidebar; the legacy nested-split PlaylistsView
/// above remains for in-place management until its migration completes.
struct PlaylistDetailView: View {
    @EnvironmentObject private var container: AppContainer
    var playlist: Playlist

    var body: some View {
        let tracks = container.readyLibrary.playlistTracks(id: playlist.id)
        VStack(alignment: .leading, spacing: 0) {
            header(tracks: tracks)
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
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                            TrackRow(track: track, context: tracks)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                container.readyLibrary.removeFromPlaylist(
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
                        container.readyLibrary.reorderPlaylist(playlistID: playlist.id, orderedTrackIDs: ids)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(playlist.name)
    }

    // MARK: - Header

    private func header(tracks: [Track]) -> some View {
        HStack(spacing: 20) {
            ArtworkView(artworkPath: playlist.artworkPath,
                        coverURL: tracks.first?.coverURL,
                        localPath: nil, size: 160)
            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.name)
                    .font(.largeTitle).fontWeight(.bold)
                    .lineLimit(2)
                if let sourceKind = linkedSourceKind {
                    Text(sourceKind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let syncStatus = linkedSyncStatus {
                    Text(syncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Play") {
                        if !tracks.isEmpty { container.player?.playTracks(tracks) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tracks.isEmpty)
                    Button("Shuffle") {
                        if !tracks.isEmpty {
                            container.player?.playTracks(tracks.shuffled())
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)
                    if let jobID = playlist.syncJobID {
                        Button("Sync Now") {
                            SyncNowRunner.run(jobID: jobID, container: container)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
    }

    /// "Spotify Playlist" etc. from the backing Source row, if linked.
    private var linkedSourceKind: String? {
        guard let sourceID = playlist.sourceID,
              let source = container.readySources.sources.first(where: { $0.id == sourceID })
        else { return nil }
        switch source.kind {
        case "spotifyPlaylist": return "Spotify Playlist"
        case "youTubePlaylist": return "YouTube Playlist"
        case "youTubeMusicLink": return "YouTube Music"
        case "spotifyAlbum": return "Spotify Album"
        case "spotifyArtist": return "Spotify Artist"
        case "spotifyTrack": return "Spotify Track"
        case "youTubeVideo": return "YouTube Video"
        default: return source.displayName.isEmpty ? nil : "Source"
        }
    }

    /// "Last synced … · Daily" etc. from the linked sync job, if any.
    private var linkedSyncStatus: String? {
        guard let jobID = playlist.syncJobID,
              let job = container.readySyncJobs.jobs.first(where: { $0.id == jobID })
        else { return nil }
        var parts: [String] = [job.schedule.label]
        if let last = job.lastSuccessAt {
            parts.append("Last synced \(last.formatted(.relative(presentation: .named)))")
        }
        if job.lastError != nil {
            parts.append("Needs attention")
        }
        return parts.joined(separator: " · ")
    }
}
