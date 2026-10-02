import SwiftUI

/// Add Playlist: the primary first-class ingest workflow.
///
/// Paste a Spotify/YouTube playlist URL → resolve → metadata + artwork +
/// track preview → confirm → Kyoku creates the playlist row, records the
/// backing Source + snapshot, creates a Sync Job with sensible defaults
/// (playlist subfolder destination, manual schedule, ask-policy removals),
/// enqueues downloads, and returns the new playlist ID for navigation.
///
/// The user never sees Source/SyncJob/snapshot objects here; power users
/// inspect them under Automation afterwards. One-off (non-playlist) URLs
/// still go through Sources → Add Source.
struct AddPlaylistView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void = { _ in }

    @State private var input = ""
    @State private var isResolving = false
    @State private var discovered: [DiscoveredTrack] = []
    @State private var errorMessage: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Playlist")
                .font(.title2).fontWeight(.bold)
            Text("Paste a Spotify or YouTube playlist link. Kyoku resolves it, downloads the tracks into their own folder, and keeps it in sync.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("https://…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { resolve() }
                    .disabled(isResolving || isCreating)
                if isResolving {
                    Button("Cancel") { resolveTask?.cancel() }
                } else {
                    Button("Continue") { resolve() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }

            if isResolving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding tracks… this can take a few minutes on first run.")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            if !discovered.isEmpty {
                previewSection
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Preview + confirm

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                playlistArtwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlistTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(playlistSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(discovered.count) track\(discovered.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            List {
                ForEach(discovered.prefix(10)) { track in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(track.artist) – \(track.title)").lineLimit(1)
                            Text(track.song.albumName)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(formatDuration(track.song.duration))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if discovered.count > 10 {
                    Text("…and \(discovered.count - 10) more")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160)
            HStack {
                Text("Downloads to \(destinationPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(isCreating ? "Adding…" : "Add Playlist") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
        }
    }

    /// Remote playlist artwork (first cover_url found), else placeholder.
    private var playlistArtwork: some View {
        ArtworkView(artworkPath: nil,
                    coverURL: discovered.compactMap(\.song.coverURL).first,
                    localPath: nil, size: 72)
    }

    private var playlistTitle: String {
        if let first = discovered.first {
            let album = first.song.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !album.isEmpty { return album }
            return "\(first.artist) – \(first.title)"
        }
        return "Playlist"
    }

    private var playlistSubtitle: String {
        switch container.readyDownloads.classifySource(
            input.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .spotifyPlaylist: return "Spotify Playlist"
        case .youTubePlaylist: return "YouTube Playlist"
        case .youTubeMusicLink: return "YouTube Music"
        case .spotifyAlbum: return "Spotify Album"
        case .spotifyArtist: return "Spotify Artist"
        case .spotifyTrack: return "Spotify Track"
        case .youTubeVideo: return "YouTube Video"
        default: return "Source"
        }
    }

    private var destinationPreview: String {
        guard let root = container.readyMusicFolderAccess.folderURL else {
            return "your music folder"
        }
        return root.appendingPathComponent(
            PlaylistDestinations.safeFolderName(for: playlistTitle),
            isDirectory: true).path
    }

    // MARK: - Resolve

    private func resolve() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        errorMessage = nil
        discovered = []
        isResolving = true
        resolveTask = Task {
            do {
                let tracks = try await container.readyDownloads.resolveSource(query)
                if !Task.isCancelled {
                    discovered = tracks
                    if tracks.isEmpty {
                        errorMessage = "No tracks found. Check the link and try again."
                    }
                }
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isResolving = false
        }
    }

    // MARK: - Create

    private func create() {
        guard !discovered.isEmpty, !isCreating else { return }
        isCreating = true
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = playlistTitle
        // Source (idempotent by URL) + snapshot from this discovery.
        let source: Source
        if let existing = container.readySources.sources.first(where: { $0.url == query }) {
            source = existing
        } else {
            let kind: String
            switch container.readyDownloads.classifySource(query) {
            case .spotifyTrack: kind = "spotifyTrack"
            case .spotifyPlaylist: kind = "spotifyPlaylist"
            case .spotifyAlbum: kind = "spotifyAlbum"
            case .spotifyArtist: kind = "spotifyArtist"
            case .youTubeVideo: kind = "youTubeVideo"
            case .youTubePlaylist: kind = "youTubePlaylist"
            case .youTubeMusicLink: kind = "youTubeMusicLink"
            case .spotdlFile: kind = "spotdlFile"
            case .searchTerm: kind = "searchTerm"
            }
            source = container.readySources.add(url: query, kind: kind, displayName: title)
        }
        container.readySources.saveSnapshot(
            sourceID: source.id,
            entries: discovered.enumerated().map {
                SnapshotEntry.from(song: $0.element.song, position: $0.offset)
            })
        // Playlist row + artwork: cache the remote cover locally so the
        // playlist screen never needs the network to render.
        let playlist = container.readyLibrary.createPlaylist(name: title, sourceID: source.id)
        if let cover = discovered.compactMap(\.song.coverURL).first {
            Task {
                let cached = await PlaylistArtwork.fetch(urlString: cover,
                                                         playlistID: playlist.id)
                await MainActor.run {
                    if let cached {
                        container.readyLibrary.setPlaylistImportLinkage(
                            id: playlist.id, sourceID: source.id,
                            artworkPath: cached, syncJobID: playlist.syncJobID)
                    }
                }
            }
        }
        linkKnownTracks(playlistID: playlist.id)
        // Sync job with playlist-folder destination; manual schedule keeps
        // the default quiet (user opts into automation via Automation).
        let destination = PlaylistDestinations.resolve(
            playlistName: title,
            musicRoot: container.readyMusicFolderAccess.folderURL,
            access: nil)
        let job = container.readySyncJobs.create(
            sourceID: source.id, name: title, destination: destination,
            profileID: container.settings.defaultProfileID,
            schedule: .manual, removalPolicy: .ask)
        container.readyLibrary.setPlaylistImportLinkage(
            id: playlist.id, sourceID: source.id,
            artworkPath: container.readyLibrary.playlists
                .first(where: { $0.id == playlist.id })?.artworkPath,
            syncJobID: job.id)
        // Enqueue everything; the queue + engine dedupe against the
        // library, so shared tracks download once. Fresh downloads attach
        // to this playlist when they complete (queue continuation).
        container.readyQueue.enqueue(discovered.map(\.song), sourceURL: source.url,
                                     syncJobID: job.id, sourceID: source.id,
                                     profileID: job.profileID)
        isCreating = false
        onCreated(playlist.id)
        dismiss()
    }

    /// Link already-downloaded tracks (same sourceURL) into the playlist.
    /// New downloads attach when they complete (queue continuation).
    private func linkKnownTracks(playlistID: String) {
        let known = discovered.compactMap { song -> String? in
            container.readyLibrary.tracks.first(where: { $0.sourceURL == song.song.url })?.id
        }
        if !known.isEmpty {
            container.readyLibrary.addToPlaylist(playlistID: playlistID, trackIDs: known)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
