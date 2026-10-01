import Combine
import Foundation

/// Composition root. Owns long-lived services; injected via @EnvironmentObject.
/// Views must not construct services directly.
///
/// Database survival (Workstream 6): the container boots in one of two
/// states. `.ready` holds the full service graph (normal library UI).
/// `.recovery` holds the classified startup error + DB path and renders
/// DatabaseRecoveryView (Retry / Reset with backup) instead. Retry re-runs
/// DatabaseBoot.boot; reset preserves the broken file as a timestamped
/// backup, then rebuilds the full service graph around the fresh DB.
///
/// NOTE: deliberately not @MainActor — @StateObject requires a nonisolated
/// init. All service access happens on the main thread via SwiftUI.
/// Revisit if background threads ever touch these stores (Phase 3).
final class AppContainer: ObservableObject {
    /// Boot state. Published so the app root swaps between recovery UI and
    /// the normal library UI without relaunching.
    enum BootState {
        case ready
        case recovery(error: DatabaseStartupError, dbPath: String)
    }

    let settings: AppSettings
    /// Non-nil exactly when bootState == .ready. Optionals (not force
    /// unwraps): views only touch these behind the ready gate in KyokuApp,
    /// so a corrupt DB can never crash a view via a nil service.
    private(set) var database: Database?
    private(set) var library: LibraryStore?
    @Published var bootState: BootState
    /// Database path for the recovery UI (retry/reset target). Set in both
    /// ready and recovery states.
    private(set) var dbPath: String
    /// User-visible backup notice after a reset ("your old database was
    /// preserved at …"). Cleared on next successful retry/reset.
    @Published var lastBackupNotice: String?
    private var engineRunner = ProcessRunner()
    @Published var resetFailure: String?
    @Published var isResetting = false
    /// Playback service. Published so views update when it's wired up
    /// (main-actor creation is deferred past nonisolated init).
    @Published var player: PlaybackService?
    var downloads: (any DownloadEngine)?
    var queue: DownloadQueue?
    var sources: SourceStore?
    var syncJobs: SyncJobStore?
    var automation: AutomationRecordStore?
    var scheduler: SyncScheduler2?
    var syncEngine: SyncEngine?
    var musicFolderAccess: MusicFolderAccess?
    let logger = KyokuLogger(subsystem: "app")

    // MARK: - Ready-state accessors (Workstream 6)
    //
    // Views render ONLY behind the .ready gate in KyokuApp, so force-unwrap
    // accessors are safe there and keep 40+ call sites unchanged. Recovery
    // UI never touches these (it uses bootState/dbPath/retry/reset only).
    // If a view ever renders without ready services it crashes LOUDLY in
    // debug rather than silently showing empty state — a wiring bug, not a
    // corrupt-DB condition (those route to recovery BEFORE any view loads).
    var readyDatabase: Database { database! }
    var readyLibrary: LibraryStore { library! }
    var readyDownloads: any DownloadEngine { downloads! }
    var readyQueue: DownloadQueue { queue! }
    var readySources: SourceStore { sources! }
    var readySyncJobs: SyncJobStore { syncJobs! }
    var readyAutomation: AutomationRecordStore { automation! }
    var readyScheduler: SyncScheduler2 { scheduler! }
    var readySyncEngine: SyncEngine { syncEngine! }
    var readyMusicFolderAccess: MusicFolderAccess { musicFolderAccess! }

    init() {
        let settings = AppSettings()
        self.settings = settings
        let resolvedPath: String = (try? Database.defaultPath()) ?? "(unknown)"
        self.dbPath = resolvedPath
        switch DatabaseBoot.boot() {
        case .ready(let db):
            self.database = db
            self.bootState = .ready
            buildServices(database: db, settings: settings)
        case .recovery(let error, let path):
            self.database = nil
            self.dbPath = path
            self.bootState = .recovery(error: error, dbPath: path)
            logger.error("Database boot failed: \(error.logDetail)")
        }
    }

    /// Test seam: boot against a disposable path (never the live DB).
    /// Production uses init().
    init(testDatabasePath: String) {
        let settings = AppSettings()
        self.settings = settings
        self.dbPath = testDatabasePath
        switch DatabaseBoot.boot(path: testDatabasePath) {
        case .ready(let db):
            self.database = db
            self.bootState = .ready
            buildServices(database: db, settings: settings)
        case .recovery(let error, let path):
            self.database = nil
            self.bootState = .recovery(error: error, dbPath: path)
        }
    }

    /// Assemble the full service graph around an open, verified Database.
    /// Single construction site: init(), retryBoot(), and resetDatabase()
    /// all converge here, so recovery rebuilds exactly what a healthy boot
    /// builds (no divergent second graph).
    private func buildServices(database db: Database, settings: AppSettings) {
        let library = LibraryStore(database: db)
        let runner = ProcessRunner()
        self.engineRunner = runner
        let downloads: any DownloadEngine = SpotDLEngine(runner: runner)
        let musicFolderAccess = MusicFolderAccess(settings: settings)
        let queue = DownloadQueue(
            database: db,
            engine: downloads,
            library: library,
            musicFolderAccess: musicFolderAccess,
            defaultProfile: { [weak settings] in settings?.defaultProfile ?? .appleLibrary },
            profileForJob: { profileID in
                // The task's profileID is the job's profile captured at
                // enqueue time; resolve against builtins (custom profiles
                // arrive in a later phase). Unknown IDs fall back to default.
                guard let profileID else { return nil }
                return DownloadProfile.builtins.first { $0.id == profileID }
            }
        )
        let sources = SourceStore(database: db)
        let syncJobs = SyncJobStore(database: db)
        let automation = AutomationRecordStore(database: db)
        let scheduler = SyncScheduler2()
        let syncEngine = SyncEngine(
            database: db,
            engine: downloads,
            queue: queue,
            library: library,
            sources: sources,
            jobs: syncJobs,
            records: automation,
            musicFolderAccess: musicFolderAccess
        )

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

    // MARK: - Recovery (Workstream 6)

    /// Re-run DatabaseBoot.boot against the same path. On success rebuilds
    /// services and flips to .ready (caller then calls start()). On failure
    /// stays in .recovery with the NEW error (a transient lock may have
    /// cleared, or corruption may have progressed — report current truth).
    /// Never destroys data: retry only reads/opens.
    @MainActor
    func retryBoot() {
        resetFailure = nil
        switch DatabaseBoot.boot(path: dbPath) {
        case .ready(let db):
            self.database = db
            buildServices(database: db, settings: settings)
            lastBackupNotice = nil
            bootState = .ready
        case .recovery(let error, _):
            logger.error("Database retry failed: \(error.logDetail)")
            bootState = .recovery(error: error, dbPath: dbPath)
        }
    }

    /// Reset-with-backup: preserve the broken file, fresh-create, rebuild.
    /// On success: services rebuilt, .ready, backup notice set. On failure:
    /// original/backup preserved, resetFailure set for the UI, stays in
    /// .recovery — never a half-initialized graph.
    @MainActor
    func resetDatabase() {
        resetFailure = nil
        isResetting = true
        defer { isResetting = false }
        do {
            let (fresh, backupURL) = try DatabaseBoot.resetDatabase(at: dbPath)
            self.database = fresh
            buildServices(database: fresh, settings: settings)
            lastBackupNotice = "Your previous database was preserved as a backup:\n\(backupURL.lastPathComponent)"
            bootState = .ready
            // New services need actor-bound startup (same as first launch).
            start()
        } catch let startup as DatabaseStartupError {
            logger.error("Database reset failed: \(startup.logDetail)")
            resetFailure = startup.userMessage
        } catch {
            logger.error("Database reset failed: \(error)")
            resetFailure = "Reset couldn't finish. Your existing data was left untouched."
        }
    }

    /// Finish main-actor wiring (player, queue worker, scheduler,
    /// interrupted-run recovery). Called once from the main thread
    /// (KyokuApp scene task). AppContainer.init stays nonisolated for
    /// @StateObject. No-op unless bootState == .ready (recovery UI owns
    /// the screen otherwise — never start workers over a broken DB).
    @MainActor
    func start() {
        guard case .ready = bootState,
              let musicFolderAccess, let queue, let sources,
              let syncJobs, let automation, let scheduler, let syncEngine
        else { return }
        startPlayer()
        // Launch-time library reconciliation (Workstream 5 semantics):
        // cheap file-existence checks only, rows NEVER deleted for missing
        // files (missingTrackIDs drives the dimmed UI). Idempotent: a
        // second start() re-derives the same set from disk.
        library?.reconcile()
        // Launch-time filesystem validation (cheap access checks only —
        // no library scan). Marks state; never deletes configuration.
        // Music folder first: everything else depends on it.
        let folderStatus = musicFolderAccess.validate()
        queue.start()
        sources.start()
        syncJobs.start()
        automation.start()
        // Custom sync destinations: surface stale ones as attention items
        // (preserved configuration, user repairs via the job editor).
        _ = syncJobs.validateAll(records: automation,
                                 musicRoot: musicFolderAccess.folderURL)
        if folderStatus != .ok, let message = musicFolderAccess.relinkMessage {
            automation.addAttention(AttentionItem(
                kind: "musicFolderInaccessible",
                title: "Music folder needs attention",
                detail: message))
        }
        // Scheduler pulls due jobs from the store; the engine runs them.
        scheduler.jobProvider = { [weak self] in self?.syncJobs?.jobs ?? [] }
        scheduler.onDueJobs = { [weak self] jobs in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let scheduler = self.scheduler,
                      let syncEngine = self.syncEngine
                else { return }
                for job in jobs {
                    scheduler.markRunning(job.id)
                    await syncEngine.run(jobID: job.id)
                    scheduler.markFinished(job.id)
                    self.syncJobs?.refresh()
                    self.sources?.refresh()
                    self.automation?.refresh()
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
            self?.library?.recordPlay(trackID: trackID)
        }
        self.player = player
    }
}
