import Foundation

/// What to do when a previously-synced source track disappears.
enum RemovalPolicy: String, Sendable, CaseIterable {
    case ask
    case keep
    case delete
}

/// Phase 0 sync-job model. Grows in Phase 3 (destination, profile ID,
/// last snapshot, error state, pause/resume, dry-run results).
struct SyncJob: Identifiable, Sendable {
    let id: String
    var sourceURL: String
    var checkInterval: TimeInterval
    var removalPolicy: RemovalPolicy
    var isPaused: Bool
    var lastCheckedAt: Date?
    var lastSyncedAt: Date?

    init(
        id: String = UUID().uuidString,
        sourceURL: String,
        checkInterval: TimeInterval = 1800,
        removalPolicy: RemovalPolicy = .ask,
        isPaused: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.checkInterval = checkInterval
        self.removalPolicy = removalPolicy
        self.isPaused = isPaused
    }
}
