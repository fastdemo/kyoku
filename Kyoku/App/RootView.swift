import SwiftUI

/// Phase 0 root: minimal sidebar shell establishing navigation structure.
/// Future phases fill in each destination.
struct RootView: View {
    @State private var selection: NavItem? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Listen") {
                    Label("Home", systemImage: "house").tag(NavItem.home)
                }
                Section("Library") {
                    Label("Songs", systemImage: "music.note").tag(NavItem.songs)
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
            switch selection ?? .home {
            case .home:
                HomeView()
            case .songs, .queue, .sources:
                PlaceholderView(item: selection ?? .home)
            }
        }
        .frame(minWidth: 800, minHeight: 550)
    }
}

enum NavItem: Hashable {
    case home
    case songs
    case queue
    case sources
}

/// Temporary stand-in for destinations built in later phases.
private struct PlaceholderView: View {
    let item: NavItem

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("Coming in a later phase.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch item {
        case .home: return "Home"
        case .songs: return "Songs"
        case .queue: return "Queue"
        case .sources: return "Sources"
        }
    }
}
