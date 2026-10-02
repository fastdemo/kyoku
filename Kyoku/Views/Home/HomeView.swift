import SwiftUI

/// Home overview: the daily entry point. Recency lives HERE as content
/// sections (not as permanent sidebar destinations): recently added,
/// recently played, playlists, and operational status (downloads in
/// progress, attention count, library summary).
///
/// Sections navigate via the shared selection binding owned by RootView;
/// Home itself holds no navigation state.
struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    var select: (NavItem) -> Void = { _ in }
    var openPlaylist: (String) -> Void = { _ in }
    @State private var backendAvailable: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if hasContent {
                    if !recentAdded.isEmpty {
                        homeSection(title: "Recently Added", destination: .songs) {
                            trackStrip(recentAdded)
                        }
                    }
                    if !recentPlayed.isEmpty {
                        homeSection(title: "Recently Played", destination: .songs) {
                            trackStrip(recentPlayed)
                        }
                    }
                    if !container.readyLibrary.playlists.isEmpty {
                        homeSection(title: "Playlists", destination: nil) {
                            playlistStrip
                        }
                    }
                    statusSection
                } else {
                    emptyState
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Home")
    }

    // MARK: - Data

    private var hasContent: Bool {
        !container.readyLibrary.tracks.isEmpty
            || !container.readyLibrary.playlists.isEmpty
            || !container.readyQueue.tasks.isEmpty
            || !container.readyAutomation.openAttention.isEmpty
    }

    private var recentAdded: [Track] {
        container.readyLibrary.recentlyAdded(limit: 8)
    }

    private var recentPlayed: [Track] {
        container.readyLibrary.recentlyPlayed(limit: 8)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(.largeTitle).fontWeight(.bold)
            Text(librarySummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var librarySummary: String {
        let tracks = container.readyLibrary.tracks.count
        let playlists = container.readyLibrary.playlists.count
        guard tracks > 0 || playlists > 0 else { return "Your music overview" }
        var parts: [String] = []
        if tracks > 0 { parts.append("\(tracks) song\(tracks == 1 ? "" : "s")") }
        if playlists > 0 { parts.append("\(playlists) playlist\(playlists == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func homeSection<Content: View>(title: String,
                                            destination: NavItem?,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title2).fontWeight(.semibold)
                Spacer()
                if let destination {
                    Button("See All") { select(destination) }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
            content()
        }
    }

    private func trackStrip(_ tracks: [Track]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                  spacing: 16) {
            ForEach(tracks.prefix(8)) { track in
                Button {
                    container.player?.play(track, in: tracks)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(artworkPath: track.artworkPath,
                                    coverURL: track.coverURL,
                                    localPath: track.localPath, size: 160)
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .trackMenu(track: track, context: tracks)
            }
        }
    }

    private var playlistStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                  spacing: 16) {
            ForEach(container.readyLibrary.playlists.prefix(8)) { playlist in
                Button {
                    openPlaylist(playlist.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(artworkPath: playlist.artworkPath,
                                    coverURL: nil, localPath: nil, size: 160)
                        Text(playlist.name)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text("\(container.readyLibrary.playlistTracks(id: playlist.id).count) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Operational status: downloads in progress + items needing action.
    /// Quiet when everything is idle (no news is good news).
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                downloadStatusRow
                attentionStatusRow
                backendStatusRow
            }
        }
    }

    @ViewBuilder
    private var downloadStatusRow: some View {
        let active = container.readyQueue.tasks.filter {
            $0.state == .pending || $0.state == .resolving
                || $0.state == .downloading || $0.state == .processing
        }
        let failed = container.readyQueue.tasks.filter { $0.state == .failed }
        if !active.isEmpty {
            Button { select(.queue) } label: {
                Label("Downloading \(active.count) track\(active.count == 1 ? "" : "s")",
                      systemImage: "arrow.down.circle")
            }
            .buttonStyle(.link)
        } else if !failed.isEmpty {
            Button { select(.queue) } label: {
                Label("\(failed.count) download\(failed.count == 1 ? "" : "s") need attention",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var attentionStatusRow: some View {
        let count = container.readyAutomation.openAttention.count
        if count > 0 {
            Button { select(.attention) } label: {
                Label("\(count) item\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") your attention",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.link)
        }
    }

    private var backendStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: backendAvailable == true ? "checkmark.circle" : "questionmark.circle")
                .foregroundStyle(backendAvailable == true ? .green : .secondary)
            Text(backendStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task { await checkBackend() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Welcome to Kyoku")
                .font(.title2).fontWeight(.semibold)
            Text("Add a playlist to start building your library — or add a source for one-off downloads.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Backend

    private var backendStatus: String {
        guard let backendAvailable else { return "Checking download engine…" }
        return backendAvailable ? "Download engine ready" : "Download engine unavailable (see Settings → Backend)"
    }

    private func checkBackend() async {
        if let engine = container.readyDownloads as? SpotDLEngine {
            backendAvailable = await engine.isAvailable()
        } else {
            backendAvailable = false
        }
    }
}
