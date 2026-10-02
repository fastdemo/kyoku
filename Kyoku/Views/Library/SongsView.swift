import SwiftUI

/// Songs: sortable table with search passthrough (global search handles
/// filtering; this view sorts the in-memory list).
struct SongsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var sort: SortKey = .dateAdded
    @State private var ascending = false

    enum SortKey: String, CaseIterable, Identifiable {
        case title, artist, album, duration, dateAdded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .artist: return "Artist"
            case .album: return "Album"
            case .duration: return "Duration"
            case .dateAdded: return "Date Added"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if sorted.isEmpty {
                emptyState
            } else {
                List(sorted) { track in
                    TrackRow(track: track, context: sorted)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Songs")
    }

    private var header: some View {
        // No in-content title: the sidebar + window title already say
        // "Songs". This bar holds only the sort controls.
        HStack {
            Text("\(sorted.count) song\(sorted.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .help(ascending ? "Ascending" : "Descending")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var sorted: [Track] {
        let tracks = container.readyLibrary.tracks
        let ordered: [Track] = switch sort {
        case .title: tracks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist: tracks.sorted { $0.artist.localizedCompare($1.artist) == .orderedAscending }
        case .album: tracks.sorted { $0.album.localizedCompare($1.album) == .orderedAscending }
        case .duration: tracks.sorted { $0.duration < $1.duration }
        case .dateAdded: tracks.sorted { $0.createdAt > $1.createdAt }
        }
        if sort == .dateAdded {
            return ascending ? ordered.reversed() : ordered
        }
        return ascending ? ordered : ordered.reversed()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No songs yet")
                .font(.headline)
            Text("Download music from Sources and it will appear here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
