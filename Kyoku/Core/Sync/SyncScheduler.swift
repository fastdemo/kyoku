import Combine
import Foundation

/// Sync scheduling strategy (Phase 0: interval bookkeeping only).
///
/// Background strategy (to be implemented in Phase 3):
/// - Foreground refresh via Timer while the app is running.
/// - Mac sleep/offline tolerance via backoff + "catch up on wake".
/// - Long-term: BGTaskScheduler (BGAppRefreshTask) for periodic checks
///   when the app isn't running. Full launchd/SMAppService helper is
///   deferred until Phase 3, after the sync engine itself is stable —
///   installing a helper before there's real work to schedule would be
///   premature and complicates sandbox/signing decisions (see Phase 6).
final class SyncScheduler: ObservableObject {
    @Published private(set) var scheduledJobs: [SyncJob] = []

    private let logger = KyokuLogger(subsystem: "core", category: "sync")

    /// Earliest date a job with this interval should next run.
    func nextFireDate(lastRun: Date?, interval: TimeInterval) -> Date {
        guard let lastRun else { return Date() }
        return max(Date(), lastRun.addingTimeInterval(interval))
    }

    /// Exponential backoff for retries: 1m, 2m, 4m … capped at 1h.
    func backoffDelay(attempt: Int) -> TimeInterval {
        min(60 * pow(2.0, Double(max(0, attempt))), 3600)
    }
}
