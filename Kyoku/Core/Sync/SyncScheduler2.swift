import Combine
import Foundation

/// Decides WHEN sync jobs run. Centralized single-timer design:
/// one 60s tick evaluates every enabled job (due? already running?
/// backoff?). No per-job timers.
///
/// - Due = lastRun + interval <= now (missed schedules run immediately).
/// - Backoff = consecutiveFailures delays the next run exponentially
///   (1m, 2m, 4m … capped at 1h), so a dead source doesn't hammer.
/// - Manual jobs never fire automatically.
/// - Sleep/wake: the tick simply re-evaluates; missed time counts as due.
/// - Restart: lastRunAt persists in SQLite; interrupted 'running' sync
///   runs are failed+recovered by SyncEngine at launch, not here.
@MainActor
final class SyncScheduler2: ObservableObject {
    /// Jobs currently executing (jobID set). Prevents overlaps.
    @Published private(set) var runningJobIDs: Set<String> = []
    @Published private(set) var lastTick: Date = Date()

    private let logger = KyokuLogger(subsystem: "core", category: "scheduler")
    private var timer: Timer?
    /// Fired by the timer; SyncEngine subscribes via onDue.
    var onDueJobs: (([SyncJobConfig]) -> Void)?

    /// Read on every tick; set by AppContainer (avoids a store dependency).
    var jobProvider: (() -> [SyncJobConfig])?

    /// Nonisolated init (cf. DownloadQueue): the timer starts via start()
    /// on the main thread after construction.
    nonisolated init() {}

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Evaluate immediately on start (catches missed schedules).
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Evaluate once (also called by tests with injected job lists).
    func tick(now: Date = Date()) {
        lastTick = now
        guard let jobs = jobProvider?() else { return }
        let due = jobs.filter { isDue($0, now: now) && !runningJobIDs.contains($0.id) }
        if !due.isEmpty {
            logger.info("Scheduler: \(due.count) job(s) due.")
            onDueJobs?(due)
        }
    }

    func markRunning(_ id: String) { runningJobIDs.insert(id) }
    func markFinished(_ id: String) { runningJobIDs.remove(id) }

    /// Pure due-check, unit-tested.
    func isDue(_ job: SyncJobConfig, now: Date) -> Bool {
        guard job.enabled else { return false }
        guard job.schedule != .manual else { return false }
        guard let lastRun = job.lastRunAt else { return true } // never run → due
        var next = lastRun.addingTimeInterval(job.schedule.interval)
        if job.consecutiveFailures > 0 {
            // Backoff pushes the next run out.
            let backoff = Self.backoff(attempt: job.consecutiveFailures)
            next = max(next, lastRun.addingTimeInterval(backoff))
        }
        return now >= next
    }

    /// Exponential backoff for retries: 1m, 2m, 4m … capped at 1h.
    static func backoff(attempt: Int) -> TimeInterval {
        min(60 * pow(2.0, Double(max(0, attempt))), 3600)
    }

    /// Human-readable next-check description for the UI.
    func nextCheckDescription(_ job: SyncJobConfig, now: Date = Date()) -> String {
        guard job.enabled else { return "Paused" }
        guard job.schedule != .manual else { return "Manual only" }
        if runningJobIDs.contains(job.id) { return "Syncing…" }
        guard let lastRun = job.lastRunAt else { return "Due now" }
        let next = lastRun.addingTimeInterval(job.schedule.interval)
        if now >= next { return "Due now" }
        let mins = Int(next.timeIntervalSince(now) / 60)
        if mins < 1 { return "Due shortly" }
        if mins < 60 { return "Next check in \(mins) min" }
        let hours = mins / 60
        if hours < 24 { return "Next check in \(hours)h" }
        return "Next check in \(hours / 24)d"
    }
}
