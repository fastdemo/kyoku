import AppKit
import SwiftUI

/// Phase 0 settings: music folder only. Download profiles and advanced
/// backend options arrive in Phase 5.
struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Form {
            Section("Music Folder") {
                HStack {
                    Text(folderDescription)
                    Spacer()
                    Button("Choose…") { pickFolder() }
                    if container.musicFolderAccess.hasFolder {
                        Button("Clear") { container.musicFolderAccess.clearFolder() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 220)
    }

    private var folderDescription: String {
        container.musicFolderAccess.folderURL?.path ?? "No folder chosen"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            container.musicFolderAccess.chooseFolder(url)
        }
    }
}
