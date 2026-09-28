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
    /// Playback service. Published so views update when it's wired up
    /// (main-actor creation is deferred past nonisolated init).
    @Published var player: PlaybackService?
    let downloads: any DownloadEngine
    let queue: DownloadQueue
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
        let runner = ProcessRunner()
        let downloads: any DownloadEngine = SpotDLEngine(runner: runner)
        let syncScheduler = SyncScheduler()
        let musicFolderAccess = MusicFolderAccess(settings: settings)
        let queue = DownloadQueue(
            database: database,
            engine: downloads,
            library: library,
            musicFolderAccess: musicFolderAccess
        )

        self.settings = settings
        self.database = database
        self.library = library
        self.downloads = downloads
        self.queue = queue
        self.syncScheduler = syncScheduler
        self.musicFolderAccess = musicFolderAccess
    }

    /// Finish main-actor wiring (player + history callback). Called once
    /// from the main thread (KyokuApp scene task), like queue.start().
    @MainActor
    func startPlayer() {
        guard player == nil else { return }
        let player = PlaybackService()
        // History: meaningful plays (see PlaybackService) land in the
        // library's playback_history + track counters.
        player.onRecordPlay = { [weak self] trackID in
            self?.library.recordPlay(trackID: trackID)
        }
        self.player = player
    }
}
