import SwiftUI

/// Recently Added: newest tracks first (the main entry point for a
/// continuously-growing library).
struct RecentlyAddedView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently Added")
                .font(.largeTitle).fontWeight(.bold)
                .padding(20)
            Divider()
            let recent = container.library.recentlyAdded(limit: 200)
            if recent.isEmpty {
                emptyState
            } else {
                List(recent) { track in
                    TrackRow(track: track, context: recent)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Recently Added")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
            Text("Music you download will appear here first.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recently Played: tracks with playback history, most recent first.
struct RecentlyPlayedView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently Played")
                .font(.largeTitle).fontWeight(.bold)
                .padding(20)
            Divider()
            let recent = container.library.recentlyPlayed(limit: 200)
            if recent.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "memories")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No playback yet")
                        .font(.headline)
                    Text("Tracks you play will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recent) { track in
                    TrackRow(track: track, context: recent)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Recently Played")
    }
}
