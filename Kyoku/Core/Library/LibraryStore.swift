import Combine
import Foundation

/// Persistent, observable library index. Database-backed; filesystem
/// reconciliation arrives in Phase 2.
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []

    private let database: Database
    private let logger = KyokuLogger(subsystem: "core", category: "library")

    init(database: Database) {
        self.database = database
        refresh()
    }

    func refresh() {
        do {
            let rows = try database.query(
                "SELECT id, title, artist, album, local_path, created_at, updated_at FROM tracks ORDER BY created_at DESC LIMIT 500;"
            )
            tracks = rows.compactMap { row in
                guard let id = row["id"]?.text,
                      let title = row["title"]?.text
                else { return nil }
                return Track(
                    id: id,
                    title: title,
                    artist: row["artist"]?.text ?? "",
                    album: row["album"]?.text ?? "",
                    localPath: row["local_path"]?.text,
                    createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                    updatedAt: row["updated_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
                )
            }
        } catch {
            logger.error("Library refresh failed: \(error.localizedDescription)")
        }
    }
}
