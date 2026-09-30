import Combine
import Foundation

/// Persistent Source store: CRUD + status updates. Thin SQLite wrapper;
/// no network, no resolution (that's SyncEngine).
@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var sources: [Source] = []

    private let database: Database
    private let logger = KyokuLogger(subsystem: "core", category: "sources")

    /// Nonisolated init (cf. DownloadQueue): actor-bound load
    /// happens via refresh() called on the main thread after init.
    nonisolated init(database: Database) {
        self.database = database
    }

    /// Actor-bound startup: load persisted rows. Called once from the
    /// main thread after construction (cf. DownloadQueue.start()).
    func start() {
        refresh()
    }

    func refresh() {
        do {
            sources = try database.query(
                "SELECT id, kind, url, display_name, artwork_path, enabled, last_checked_at, last_success_at, last_error, created_at, updated_at FROM sources ORDER BY created_at;"
            ).compactMap(Self.make)
        } catch {
            logger.error("Sources load failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func add(url: String, kind: String, displayName: String) -> Source {
        let source = Source(kind: kind, url: url, displayName: displayName)
        persist(source)
        refresh()
        return source
    }

    func update(_ source: Source) {
        var s = source
        s.updatedAt = Date()
        persist(s)
        refresh()
    }

    func remove(id: String) {
        do {
            try database.execute("DELETE FROM sources WHERE id=?;", [.text(id)])
        } catch {
            logger.error("Source remove failed: \(error.localizedDescription)")
            return
        }
        refresh()
    }

    func setEnabled(id: String, enabled: Bool) {
        guard var s = sources.first(where: { $0.id == id }) else { return }
        s.enabled = enabled
        update(s)
    }

    func recordCheck(id: String, success: Bool, error: String? = nil) {
        guard var s = sources.first(where: { $0.id == id }) else { return }
        let now = Date()
        s.lastCheckedAt = now
        if success {
            s.lastSuccessAt = now
            s.lastError = nil
        } else {
            s.lastError = error
        }
        update(s)
    }

    // MARK: - Snapshots (persisted change-detection state)

    func loadSnapshot(sourceID: String) -> [SnapshotEntry] {
        do {
            guard let row = try database.query(
                "SELECT snapshot_json FROM source_snapshots WHERE source_id=?;",
                [.text(sourceID)]
            ).first,
                let json = row["snapshot_json"]?.text,
                let data = json.data(using: .utf8)
            else { return [] }
            return (try? JSONDecoder().decode([SnapshotEntry].self, from: data)) ?? []
        } catch {
            logger.error("Snapshot load failed: \(error.localizedDescription)")
            return []
        }
    }

    func saveSnapshot(sourceID: String, entries: [SnapshotEntry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            try database.execute(
                """
                INSERT INTO source_snapshots (source_id, snapshot_json, track_count, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    snapshot_json=excluded.snapshot_json, track_count=excluded.track_count,
                    updated_at=excluded.updated_at;
                """,
                [.text(sourceID), .text(json), .integer(entries.count),
                 .real(Date().timeIntervalSince1970)]
            )
        } catch {
            logger.error("Snapshot save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static func make(_ row: [String: SQLiteValue]) -> Source? {
        guard let id = row["id"]?.text, let url = row["url"]?.text else { return nil }
        func date(_ key: String) -> Date? {
            row[key]?.real.map(Date.init(timeIntervalSince1970:))
        }
        return Source(
            id: id,
            kind: row["kind"]?.text ?? "unknown",
            url: url,
            displayName: row["display_name"]?.text ?? "",
            artworkPath: row["artwork_path"]?.text,
            enabled: (row["enabled"]?.integer ?? 1) != 0,
            lastCheckedAt: date("last_checked_at"),
            lastSuccessAt: date("last_success_at"),
            lastError: row["last_error"]?.text,
            createdAt: date("created_at") ?? Date(),
            updatedAt: date("updated_at") ?? Date()
        )
    }

    private func persist(_ source: Source) {
        do {
            try database.execute(
                """
                INSERT INTO sources (id, kind, url, display_name, artwork_path, enabled, last_checked_at, last_success_at, last_error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind=excluded.kind, url=excluded.url, display_name=excluded.display_name,
                    artwork_path=excluded.artwork_path, enabled=excluded.enabled,
                    last_checked_at=excluded.last_checked_at, last_success_at=excluded.last_success_at,
                    last_error=excluded.last_error, updated_at=excluded.updated_at;
                """,
                [.text(source.id), .text(source.kind), .text(source.url),
                 .text(source.displayName),
                 source.artworkPath.map(SQLiteValue.text) ?? .null,
                 .integer(source.enabled ? 1 : 0),
                 source.lastCheckedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                 source.lastSuccessAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                 source.lastError.map(SQLiteValue.text) ?? .null,
                 .real(source.createdAt.timeIntervalSince1970),
                 .real(source.updatedAt.timeIntervalSince1970)]
            )
        } catch {
            logger.error("Source persist failed: \(error.localizedDescription)")
        }
    }
}
