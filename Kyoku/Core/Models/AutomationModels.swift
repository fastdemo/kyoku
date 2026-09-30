import Foundation

/// Persistent external music source: where music comes from.
/// SyncJob (separate) describes what Kyoku should DO with it.
struct Source: Identifiable, Hashable, Sendable {
    let id: String
    /// Syntactic classification at add time (SourceKind raw string).
    var kind: String
    var url: String
    var displayName: String
    var artworkPath: String?
    var enabled: Bool
    var lastCheckedAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, kind: String = "unknown", url: String,
         displayName: String = "", artworkPath: String? = nil, enabled: Bool = true,
         lastCheckedAt: Date? = nil, lastSuccessAt: Date? = nil, lastError: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.url = url
        self.displayName = displayName
        self.artworkPath = artworkPath
        self.enabled = enabled
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What Kyoku should do with a Source: destination, profile, schedule,
/// removal behavior, enabled state. Separate from the Source itself so
/// one source can feed multiple jobs later.
struct SyncJobConfig: Identifiable, Hashable, Sendable {
    let id: String
    var sourceID: String
    var name: String
    /// Destination folder path (absolute). Falls back to the music folder
    /// root when blank.
    var destination: String
    var profileID: String
    var schedule: SyncSchedule
    var removalPolicy: RemovalPolicy
    var enabled: Bool
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var consecutiveFailures: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, sourceID: String, name: String = "",
         destination: String = "", profileID: String = DownloadProfile.appleLibrary.id,
         schedule: SyncSchedule = .manual, removalPolicy: RemovalPolicy = .ask,
         enabled: Bool = true, lastRunAt: Date? = nil, lastSuccessAt: Date? = nil,
         lastError: String? = nil, consecutiveFailures: Int = 0,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.destination = destination
        self.profileID = profileID
        self.schedule = schedule
        self.removalPolicy = removalPolicy
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var profile: DownloadProfile {
        DownloadProfile.builtins.first { $0.id == profileID } ?? .appleLibrary
    }
}

/// What to do when a previously-synced source track disappears.
/// Display labels live next to the raw values (persisted in SQLite).
enum RemovalPolicy: String, Sendable, CaseIterable {
    /// Keep local files; only note the removal (or ignore silently).
    case keep
    /// Surface each removed track in Needs Attention for an explicit decision.
    case ask
    /// Remove the library entry automatically (files stay on disk; only
    /// the explicit Delete File action touches the filesystem).
    case delete

    var label: String {
        switch self {
        case .keep: return "Never remove"
        case .ask: return "Ask before removing"
        case .delete: return "Automatically remove"
        }
    }
}

/// Check schedule for a sync job. Raw values persist in SQLite.
enum SyncSchedule: String, Sendable, CaseIterable {
    case manual
    case every15Minutes
    case every30Minutes
    case hourly
    case every6Hours
    case daily

    /// Nominal interval. Manual = infinity (never due automatically).
    var interval: TimeInterval {
        switch self {
        case .manual: return .infinity
        case .every15Minutes: return 900
        case .every30Minutes: return 1800
        case .hourly: return 3600
        case .every6Hours: return 21600
        case .daily: return 86400
        }
    }

    var label: String {
        switch self {
        case .manual: return "Manual only"
        case .every15Minutes: return "Every 15 minutes"
        case .every30Minutes: return "Every 30 minutes"
        case .hourly: return "Every hour"
        case .every6Hours: return "Every 6 hours"
        case .daily: return "Daily"
        }
    }
}

/// One persisted execution of a sync job. Observable + recoverable:
/// a run left 'running' at launch was interrupted (crash/kill).
struct SyncRun: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable {
        case running, succeeded, partiallySucceeded, failed, cancelled
    }

    let id: String
    var syncJobID: String
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var addedCount: Int = 0
    var removedCount: Int = 0
    var changedCount: Int = 0
    var unchangedCount: Int = 0
    var queuedCount: Int = 0
    var downloadedCount: Int = 0
    var failedCount: Int = 0
    var error: String?

    init(id: String = UUID().uuidString, syncJobID: String, startedAt: Date = Date()) {
        self.id = id
        self.syncJobID = syncJobID
        self.startedAt = startedAt
        self.status = .running
    }
}

/// A stable snapshot entry: one remote track as last seen.
/// Identity = Spotify/canonical URL when present, else title+artist key.
/// `fingerprint` lets later phases detect metadata changes cheaply.
struct SnapshotEntry: Hashable, Sendable, Codable {
    var key: String
    var url: String
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var position: Int

    /// Stable identity for a resolved song. Prefers the canonical URL
    /// (Spotify track URL); falls back to a normalized title+artist key
    /// for search-term / provider results without stable URLs.
    static func key(for song: ResolvedSong, position: Int) -> String {
        let url = song.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.lowercased().hasPrefix("http") { return "url:" + url.lowercased() }
        let norm = { (s: String) in
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return "ta:\(norm(song.artist))|\(norm(song.name))"
    }

    static func from(song: ResolvedSong, position: Int) -> SnapshotEntry {
        SnapshotEntry(
            key: key(for: song, position: position),
            url: song.url,
            title: song.name,
            artist: song.artist,
            album: song.albumName,
            duration: song.duration,
            position: position
        )
    }
}

/// Diff between the persisted snapshot and a fresh resolution.
struct ChangeSet: Sendable {
    /// Entries present now but not before (need download).
    var added: [SnapshotEntry] = []
    /// Entries present before but not now (removal policy applies).
    var removed: [SnapshotEntry] = []
    /// Same key, materially different metadata (title/artist/duration).
    /// Phase 3 re-downloads changed entries; finer update-in-place is later.
    var changed: [(old: SnapshotEntry, new: SnapshotEntry)] = []
    var unchangedCount: Int = 0

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    /// Pure function — the unit-tested heart of change detection.
    /// Order-insensitive (playlist reorder alone = no changes).
    static func diff(old: [SnapshotEntry], new: [SnapshotEntry]) -> ChangeSet {
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out = ChangeSet()
        for entry in new {
            guard let prev = oldByKey[entry.key] else {
                if !out.added.contains(where: { $0.key == entry.key }) { out.added.append(entry) }
                continue
            }
            if prev.title != entry.title || prev.artist != entry.artist
                || prev.album != entry.album || abs(prev.duration - entry.duration) > 2 {
                if !out.changed.contains(where: { $0.new.key == entry.key }) {
                    out.changed.append((old: prev, new: entry))
                }
            } else {
                out.unchangedCount += 1
            }
        }
        for entry in old where newByKey[entry.key] == nil {
            if !out.removed.contains(where: { $0.key == entry.key }) { out.removed.append(entry) }
        }
        return out
    }
}

/// User-facing automation problem. Kinds: matchFailed, downloadFailed,
/// sourceFailed, removalPending (ask-policy removals awaiting decision).
struct AttentionItem: Identifiable, Hashable, Sendable {
    let id: String
    var kind: String
    var title: String
    var detail: String
    var syncJobID: String?
    var sourceURL: String?
    var trackURL: String?
    var taskID: String?
    var isOpen: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, kind: String, title: String, detail: String = "",
         syncJobID: String? = nil, sourceURL: String? = nil, trackURL: String? = nil,
         taskID: String? = nil, isOpen: Bool = true,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.syncJobID = syncJobID
        self.sourceURL = sourceURL
        self.trackURL = trackURL
        self.taskID = taskID
        self.isOpen = isOpen
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One human-readable Activity feed row.
struct ActivityEvent: Identifiable, Hashable, Sendable {
    let id: Int
    var syncJobID: String?
    var kind: String
    var title: String
    var detail: String
    var createdAt: Date
}
