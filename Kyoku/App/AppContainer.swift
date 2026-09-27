import Combine
import Foundation

/// Composition root. Owns long-lived services; injected via @EnvironmentObject.
/// Views must not construct services directly.
///
/// NOTE: deliberately not @MainActor — @StateObject requires a nonisolated
/// init. All service access happens on the main thread via SwiftUI.
/// Revisit if background threads ever touch these stores (Phase 3).
final class AppContainer: ObservableObject {
    let settings: AppSettings
    let database: Database
    let library: LibraryStore
    let player: PlayerService
    let downloads: any DownloadEngine
    let syncScheduler: SyncScheduler
    let musicFolderAccess: MusicFolderAccess
    let logger = KyokuLogger(subsystem: "app")

    init() {
        let settings = AppSettings()
        let database: Database
        do {
            database = try Database()
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        let library = LibraryStore(database: database)
        let player = PlayerService()
        let runner = ProcessRunner()
        let downloads: any DownloadEngine = SpotDLEngine(runner: runner)
        let syncScheduler = SyncScheduler()
        let musicFolderAccess = MusicFolderAccess(settings: settings)

        self.settings = settings
        self.database = database
        self.library = library
        self.player = player
        self.downloads = downloads
        self.syncScheduler = syncScheduler
        self.musicFolderAccess = musicFolderAccess
    }
}
