import Combine
import Foundation

/// Security-scoped bookmark access to the user-chosen music folder.
///
/// Lifecycle (single authoritative implementation — views call
/// chooseFolder/clearFolder/validate, never raw bookmark APIs):
///   NSOpenPanel → chooseFolder(url) → bookmarkData(.withSecurityScope)
///   → persisted in AppSettings → resolveBookmark() on init/re-pick →
///   startAccessingSecurityScopedResource → folderURL live →
///   stopAccessing() on re-pick/clear.
///
/// Assumptions made explicit:
/// - The bookmark is app-scope, created from a user-selected URL.
/// - `folderURL != nil` does NOT prove access: validation (validate())
///   checks existence, directory-ness, and startAccessing success.
/// - Stale bookmarks refresh when the target is still usable; otherwise
///   the stored bookmark is dropped and the user must relink (Workstream 4
///   behavior — never silently keep a known-broken bookmark).
final class MusicFolderAccess: ObservableObject {
    /// Validation outcome for UI (Settings relink prompt, attention items).
    enum FolderStatus: Equatable, Sendable {
        case ok
        case noFolder
        case missingOnDisk
        case notDirectory
        case accessDenied
        case staleNeedsRelink
    }

    @Published private(set) var folderURL: URL?
    /// Last validation result. Updated by validate(); resolveBookmark sets
    /// a preliminary value synchronously on init.
    @Published private(set) var status: FolderStatus = .noFolder

    private let settings: AppSettings
    private let logger = KyokuLogger(subsystem: "app", category: "filesystem")
    private var accessing = false

    init(settings: AppSettings) {
        self.settings = settings
        resolveBookmark()
    }

#if DEBUG
    /// Test hook: bypass security-scoped bookmarks (unavailable in the
    /// test host). Production always goes through chooseFolder.
    func setFolderForTests(_ url: URL?) {
        stopAccessing()
        folderURL = url
    }
#endif

    var hasFolder: Bool { folderURL != nil }

    func chooseFolder(_ url: URL) {
        stopAccessing()
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            settings.musicFolderBookmark = bookmark
            resolveBookmark()
        } catch {
            logger.error("Bookmark creation failed: \(error.localizedDescription)")
        }
    }

    func clearFolder() {
        stopAccessing()
        // Clearing removes the stored bookmark too — no apparently-valid
        // stale bookmark may survive. Actual music files are untouched.
        settings.musicFolderBookmark = nil
        folderURL = nil
        status = .noFolder
    }

    private func resolveBookmark() {
        guard let data = settings.musicFolderBookmark else {
            folderURL = nil
            status = .noFolder
            return
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                // Try to refresh: if the target is still a usable directory,
                // re-save the bookmark and continue. Otherwise drop the
                // broken bookmark and require an explicit relink — never
                // retain a known-invalid bookmark.
                if Self.isUsableDirectory(url) {
                    do {
                        let fresh = try url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil)
                        settings.musicFolderBookmark = fresh
                        logger.info("Refreshed stale music folder bookmark.")
                    } catch {
                        logger.error("Bookmark refresh failed: \(error.localizedDescription)")
                    }
                } else {
                    logger.info("Music folder bookmark is stale and unusable; relink required.")
                    settings.musicFolderBookmark = nil
                    folderURL = nil
                    status = .staleNeedsRelink
                    return
                }
            }
            if url.startAccessingSecurityScopedResource() {
                accessing = true
                folderURL = url
                status = .ok
            } else {
                // Access denied is a real error state, not a silent nil.
                logger.error("Security-scoped access denied for music folder.")
                folderURL = nil
                status = .accessDenied
            }
        } catch {
            logger.error("Bookmark resolution failed: \(error.localizedDescription)")
            folderURL = nil
            // Corrupt bookmark data: drop it so every relaunch doesn't
            // re-hit the same failure; the user relinks once.
            settings.musicFolderBookmark = nil
            status = .staleNeedsRelink
        }
    }

    /// Validate the configured folder right now: exists, is a directory,
    /// and security-scoped access actually starts. Updates `status` and
    /// returns it. Cheap (no library scan) — safe to call at launch.
    /// Never deletes configuration; marks state for the UI to surface.
    @discardableResult
    func validate() -> FolderStatus {
        guard settings.musicFolderBookmark != nil else {
            status = .noFolder
            folderURL = nil
            return status
        }
        guard let url = folderURL else {
            // resolveBookmark already classified the failure; re-run it to
            // pick up external changes (folder restored, etc.).
            resolveBookmark()
            return status
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            status = .missingOnDisk
            return status
        }
        guard isDir.boolValue else {
            status = .notDirectory
            return status
        }
        // Re-affirm access each validation: the kernel may have revoked it.
        if url.startAccessingSecurityScopedResource() {
            url.stopAccessingSecurityScopedResource()
            status = .ok
        } else {
            status = .accessDenied
        }
        return status
    }

    /// User-facing relink explanation for Settings/attention surfaces.
    /// Nil when no action is needed. No bookmark/NSURL jargon.
    var relinkMessage: String? {
        switch status {
        case .ok, .noFolder:
            return nil
        case .missingOnDisk:
            return "Your music folder is no longer accessible. Choose it again to reconnect Kyoku."
        case .notDirectory:
            return "The saved music location is no longer a folder. Choose a folder to reconnect Kyoku."
        case .accessDenied:
            return "Kyoku no longer has permission to access your music folder. Choose it again to restore access."
        case .staleNeedsRelink:
            return "Your music folder needs to be reconnected. Choose it again to continue."
        }
    }

    private static func isUsableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private func stopAccessing() {
        if accessing {
            folderURL?.stopAccessingSecurityScopedResource()
            accessing = false
        }
    }
}
