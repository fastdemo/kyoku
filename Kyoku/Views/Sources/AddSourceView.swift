import SwiftUI

/// Add Source sheet: paste URL → resolve via the production engine →
/// preview → Download Once (Phase 1 flow, preserved) or Create Sync Job.
/// Resolved sources persist even for one-off downloads (snapshot + name).
struct AddSourceView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isResolving = false
    @State private var discovered: [DiscoveredTrack] = []
    @State private var errorMessage: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var showingJobEditor = false
    @State private var pendingSource: Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Source")
                .font(.title2).fontWeight(.bold)
            Text("Paste a Spotify or YouTube URL.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("https://…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { resolve() }
                    .disabled(isResolving)
                if isResolving {
                    Button("Cancel") { resolveTask?.cancel() }
                } else {
                    Button("Continue") { resolve() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
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
                resultsSection
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingJobEditor) {
            if let pendingSource {
                SyncJobEditorView(source: pendingSource, onDone: {
                    showingJobEditor = false
                    dismiss()
                })
                .environmentObject(container)
                .frame(minWidth: 520, minHeight: 460)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(discovered.count) track\(discovered.count == 1 ? "" : "s") found")
                .font(.headline)
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
                Button("Download Once") {
                    downloadOnce()
                    dismiss()
                }
                Spacer()
                Button("Create Sync Job") {
                    createSourceAndJob()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func resolve() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        errorMessage = nil
        discovered = []
        isResolving = true
        resolveTask = Task {
            do {
                let tracks = try await container.downloads.resolveSource(query)
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

    /// Persist the source row (idempotent by URL), return it.
    private func ensureSource() -> Source {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = container.sources.sources.first(where: { $0.url == query }) {
            return existing
        }
        // Classify synchronously (no network) for the kind string.
        // SourceKind has no raw value; derive a stable string per case.
        let kind: String
        switch container.downloads.classifySource(query) {
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
        return container.sources.add(url: query, kind: kind, displayName: guessedName)
    }

    private var guessedName: String {
        // Best-effort display name from the first result; the sync run
        // refines it from the source when possible.
        if let first = discovered.first {
            return "\(first.artist) – \(first.song.albumName.isEmpty ? first.title : first.song.albumName)"
        }
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadOnce() {
        let source = ensureSource()
        container.sources.saveSnapshot(
            sourceID: source.id,
            entries: discovered.enumerated().map {
                SnapshotEntry.from(song: $0.element.song, position: $0.offset)
            })
        container.queue.enqueue(discovered.map(\.song), sourceURL: source.url,
                                sourceID: source.id)
    }

    private func createSourceAndJob() {
        pendingSource = ensureSource()
        // Snapshot now so the first sync diffs correctly.
        if let pendingSource {
            container.sources.saveSnapshot(
                sourceID: pendingSource.id,
                entries: discovered.enumerated().map {
                    SnapshotEntry.from(song: $0.element.song, position: $0.offset)
                })
        }
        showingJobEditor = true
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
