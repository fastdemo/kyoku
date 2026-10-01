import AppKit
import SwiftUI

/// Settings: library location, default profile, notifications, backend.
/// Completed in Workstream 3 (was music-folder-only).
struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var backendStatus: BackendStatus = .checking

    var body: some View {
        Form {
            Section("Library") {
                HStack {
                    Text(container.readyMusicFolderAccess.folderURL?.path ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        _ = FolderPicker.pickAndStoreMusicFolder(
                            access: container.readyMusicFolderAccess)
                    }
                    if container.readyMusicFolderAccess.hasFolder {
                        Button("Clear") { container.readyMusicFolderAccess.clearFolder() }
                    }
                }
                // Actionable relink state (Workstream 4): stale/moved/
                // permission-lost folders explain themselves here instead
                // of failing later as opaque download errors.
                if let message = container.readyMusicFolderAccess.relinkMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reconnect Folder…") {
                        _ = FolderPicker.pickAndStoreMusicFolder(
                            access: container.readyMusicFolderAccess)
                    }
                }
            }

            Section("Downloads") {
                Picker("Default profile", selection: profileBinding) {
                    ForEach(DownloadProfile.builtins) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Used for one-off downloads. Sync jobs keep their own profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Sync notifications", isOn: notificationBinding)
                Text("One summary per sync run. Never per track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backend") {
                HStack {
                    Text(backendDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .task { await refreshBackend() }
                if backendStatus == .missing {
                    Text("spotdl was not found. Install it to enable downloads:")
                        .font(.caption)
                    Text("pip install spotdl  (requires Python 3.9+)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Kyoku looks in its bundled backend, then /opt/homebrew/bin, /usr/local/bin, and the Python framework folder. Bundled installation arrives in Phase 6.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }

    // MARK: - Bindings

    private var profileBinding: Binding<String> {
        Binding(
            get: { container.settings.defaultProfileID },
            set: { container.settings.defaultProfileID = $0 }
        )
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { SyncNotifier.enabled },
            set: { SyncNotifier.enabled = $0 }
        )
    }

    // MARK: - Backend

    private enum BackendStatus: Equatable {
        case checking
        case available(version: String?)
        case missing
    }

    private var backendDescription: String {
        switch backendStatus {
        case .checking:
            return "Checking…"
        case .available(let version):
            return version.map { "spotdl available (\($0))" } ?? "spotdl available"
        case .missing:
            return "spotdl not found"
        }
    }

    private func refreshBackend() async {
        guard let engine = container.readyDownloads as? SpotDLEngine else {
            backendStatus = .missing
            return
        }
        if await engine.isAvailable() {
            backendStatus = .available(version: await engine.backendVersion())
        } else {
            backendStatus = .missing
        }
    }
}
