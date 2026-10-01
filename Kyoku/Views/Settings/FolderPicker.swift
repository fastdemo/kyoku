import AppKit
import SwiftUI

/// Single shared folder picker. Replaces the three divergent NSOpenPanel
/// copies (SettingsView, HomeView, SyncJobEditorView).
///
/// - Directory-only, single selection, can create.
/// - Returns nil on cancel (callers keep existing state).
/// - Security-scoped persistence stays in MusicFolderAccess.chooseFolder;
///   this helper only runs the panel. Sync-job destinations store the raw
///   path (Workstream 4 hardens those bookmarks).
enum FolderPicker {
    /// Present a directory picker modally. Nil when cancelled.
    static func pickDirectory(prompt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let prompt { panel.prompt = prompt }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Pick + persist via the shared MusicFolderAccess (bookmark path).
    /// Returns true when a folder was chosen and stored.
    static func pickAndStoreMusicFolder(access: MusicFolderAccess) -> Bool {
        guard let url = pickDirectory(prompt: "Choose") else { return false }
        access.chooseFolder(url)
        return access.hasFolder
    }
}
