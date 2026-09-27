import Combine
import Foundation

/// Security-scoped bookmark access to the user-chosen music folder.
/// Persisted in AppSettings; resolved on launch. Handles stale bookmarks
/// and missing folders without crashing.
final class MusicFolderAccess: ObservableObject {
    @Published private(set) var folderURL: URL?

    private let settings: AppSettings
    private let logger = KyokuLogger(subsystem: "app", category: "filesystem")
    private var accessing = false

    init(settings: AppSettings) {
        self.settings = settings
        resolveBookmark()
    }

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
        settings.musicFolderBookmark = nil
        folderURL = nil
    }

    private func resolveBookmark() {
        guard let data = settings.musicFolderBookmark else {
            folderURL = nil
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
                logger.info("Music folder bookmark is stale; user must re-pick folder.")
                folderURL = nil
                return
            }
            if url.startAccessingSecurityScopedResource() {
                accessing = true
            }
            folderURL = url
        } catch {
            logger.error("Bookmark resolution failed: \(error.localizedDescription)")
            folderURL = nil
        }
    }

    private func stopAccessing() {
        if accessing {
            folderURL?.stopAccessingSecurityScopedResource()
            accessing = false
        }
    }
}
