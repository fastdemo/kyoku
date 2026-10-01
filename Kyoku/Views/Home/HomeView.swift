import AppKit
import SwiftUI

/// Phase 0 home: proves the foundation works — folder state, backend
/// availability, library count. Real Home UX arrives in Phase 2.
struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var backendAvailable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Home")
                .font(.largeTitle)
                .fontWeight(.bold)

            GroupBox("Music Folder") {
                HStack {
                    Text(container.readyMusicFolderAccess.hasFolder ? "Configured" : "Not chosen")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { pickFolder() }
                }
            }

            GroupBox("Download Backend") {
                HStack {
                    Text(backendStatus)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .task { await checkBackend() }
            }

            GroupBox("Library") {
                Text("\(container.readyLibrary.tracks.count) tracks indexed")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var backendStatus: String {
        guard let backendAvailable else { return "Checking…" }
        return backendAvailable ? "spotdl available" : "spotdl not found (expected in Phase 0)"
    }

    private func pickFolder() {
        _ = FolderPicker.pickAndStoreMusicFolder(access: container.readyMusicFolderAccess)
    }

    private func checkBackend() async {
        if let engine = container.readyDownloads as? SpotDLEngine {
            backendAvailable = await engine.isAvailable()
        } else {
            backendAvailable = false
        }
    }
}
