import SwiftUI

/// Persistent Sources: list + add (resolve → Download Once / Create Sync
/// Job) + enable/disable + delete + Sync Now shortcut. Consolidates the
/// old Phase 1 one-off Sources screen: the add flow is preserved, and
/// resolved sources can now persist.
struct SourcesView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showingAdd = false
    @State private var runningJobID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if container.readySources.sources.isEmpty {
                emptyState
            } else {
                List(container.readySources.sources) { source in
                    SourceRow(source: source, runningJobID: runningJobID)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Sources")
        .sheet(isPresented: $showingAdd) {
            AddSourceView()
                .environmentObject(container)
                .frame(minWidth: 520, minHeight: 480)
        }
    }

    private var header: some View {
        // No in-content title: the sidebar + window title already say
        // "Sources". This bar holds the count + primary action.
        HStack {
            Text("\(container.readySources.sources.count) source\(container.readySources.sources.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Add Source") { showingAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No Sources")
                .font(.headline)
            Text("Add a Spotify or YouTube playlist to start building your library automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Source") { showingAdd = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SourceRow: View {
    @EnvironmentObject private var container: AppContainer
    var source: Source
    var runningJobID: String?
    @State private var confirmDelete = false

    var body: some View {
        let jobs = container.readySyncJobs.jobs.filter { $0.sourceID == source.id }
        let snapshotCount = snapshotTrackCount
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName.isEmpty ? source.url : source.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle(trackCount: snapshotCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let error = source.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !source.enabled {
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if jobs.contains(where: { $0.id == runningJobID }) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(source.enabled ? "Pause" : "Resume") {
                container.readySources.setEnabled(id: source.id, enabled: !source.enabled)
            }
            if let job = jobs.first {
                Button("Sync Now") {
                    SyncNowRunner.run(jobID: job.id, container: container)
                }
                .disabled(!source.enabled)
            }
            Divider()
            Button("Delete Source", role: .destructive) {
                confirmDelete = true
            }
        }
        .confirmationDialog("Delete this source?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Source", role: .destructive) {
                container.readySources.remove(id: source.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Deleting a source removes its sync jobs and snapshots.
            // Downloaded tracks stay in the library.
            Text("Sync jobs for this source are removed too. Downloaded tracks stay in your library.")
        }
    }

    private var icon: String {
        switch source.kind {
        case "spotifyPlaylist", "spotifyAlbum", "spotifyArtist", "spotifyTrack": return "music.note.list"
        case "youTubePlaylist", "youTubeVideo", "youTubeMusicLink": return "play.rectangle"
        default: return "magnifyingglass"
        }
    }

    private var snapshotTrackCount: Int? {
        // Cheap: read from the snapshot row without decoding JSON.
        // SourceStore exposes full entries; count suffices here.
        let entries = container.readySources.loadSnapshot(sourceID: source.id)
        return entries.isEmpty ? nil : entries.count
    }

    private func subtitle(trackCount: Int?) -> String {
        var parts: [String] = [kindLabel]
        if let trackCount { parts.append("\(trackCount) track\(trackCount == 1 ? "" : "s")") }
        if let checked = source.lastCheckedAt {
            parts.append("Checked \(checked.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var kindLabel: String {
        switch source.kind {
        case "spotifyPlaylist": return "Spotify Playlist"
        case "spotifyAlbum": return "Spotify Album"
        case "spotifyArtist": return "Spotify Artist"
        case "spotifyTrack": return "Spotify Track"
        case "youTubePlaylist": return "YouTube Playlist"
        case "youTubeVideo": return "YouTube Video"
        case "youTubeMusicLink": return "YouTube Music"
        case "spotdlFile": return "spotDL File"
        case "searchTerm": return "Search"
        default: return "Source"
        }
    }
}

/// Runs a Sync Now from any view without duplicating task wiring.
enum SyncNowRunner {
    static func run(jobID: String, container: AppContainer) {
        Task { @MainActor in
            container.readyScheduler.markRunning(jobID)
            await container.readySyncEngine.run(jobID: jobID)
            container.readyScheduler.markFinished(jobID)
            container.readySyncJobs.refresh()
            container.readySources.refresh()
            container.readyAutomation.refresh()
        }
    }
}
