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
    let sources: SourceStore
    let syncJobs: SyncJobStore
    let automation: AutomationRecordStore
    let scheduler: SyncScheduler2
    let syncEngine: SyncEngine
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
        let musicFolderAccess = MusicFolderAccess(settings: settings)
        let queue = DownloadQueue(
            database: database,
            engine: downloads,
            library: library,
            musicFolderAccess: musicFolderAccess
        )
        let sources = SourceStore(database: database)
        let syncJobs = SyncJobStore(database: database)
        let automation = AutomationRecordStore(database: database)
        let scheduler = SyncScheduler2()
        let syncEngine = SyncEngine(
            database: database,
            engine: downloads,
            queue: queue,
            library: library,
            sources: sources,
            jobs: syncJobs,
            records: automation,
            musicFolderAccess: musicFolderAccess
        )

        self.settings = settings
        self.database = database
        self.library = library
        self.downloads = downloads
        self.queue = queue
        self.sources = sources
        self.syncJobs = syncJobs
        self.automation = automation
        self.scheduler = scheduler
        self.syncEngine = syncEngine
        self.musicFolderAccess = musicFolderAccess
    }

    /// Finish main-actor wiring (player, queue worker, scheduler,
    /// interrupted-run recovery). Called once from the main thread
    /// (KyokuApp scene task). AppContainer.init stays nonisolated for
    /// @StateObject.
    @MainActor
    func start() {
        startPlayer()
        queue.start()
        sources.start()
        syncJobs.start()
        automation.start()
        // Scheduler pulls due jobs from the store; the engine runs them.
        scheduler.jobProvider = { [weak self] in self?.syncJobs.jobs ?? [] }
        scheduler.onDueJobs = { [weak self] jobs in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for job in jobs {
                    scheduler.markRunning(job.id)
                    await syncEngine.run(jobID: job.id)
                    scheduler.markFinished(job.id)
                    syncJobs.refresh()
                    sources.refresh()
                    automation.refresh()
                }
            }
        }
        scheduler.start()
        syncEngine.recoverInterruptedRuns()
        SyncNotifier.requestAuthorization()
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
