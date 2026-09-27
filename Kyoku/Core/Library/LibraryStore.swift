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
                "SELECT id, title, artist, album, album_artist, duration, source_url, cover_url, local_path, created_at, updated_at FROM tracks ORDER BY created_at DESC LIMIT 500;"
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
                    albumArtist: row["album_artist"]?.text ?? "",
                    duration: row["duration"]?.integer ?? 0,
                    sourceURL: row["source_url"]?.text,
                    coverURL: row["cover_url"]?.text,
                    localPath: row["local_path"]?.text,
                    createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                    updatedAt: row["updated_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
                )
            }
        } catch {
            logger.error("Library refresh failed: \(error.localizedDescription)")
        }
    }

    /// Index a freshly downloaded file. Called by the queue on completion.
    /// Duplicate source URLs are ignored (re-downloads update the path).
    func importFile(at url: URL, song: ResolvedSong?) {
        let now = Date()
        let track = Track(
            title: song?.name ?? url.deletingPathExtension().lastPathComponent,
            artist: song?.artist ?? "",
            album: song?.albumName ?? "",
            albumArtist: song?.albumArtist ?? "",
            duration: song?.duration ?? 0,
            sourceURL: song?.url,
            coverURL: song?.coverURL,
            localPath: url.path,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.execute(
                """
                INSERT INTO tracks (id, title, artist, album, album_artist, duration, source_url, cover_url, local_path, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, artist=excluded.artist, album=excluded.album,
                    album_artist=excluded.album_artist, duration=excluded.duration,
                    source_url=excluded.source_url, cover_url=excluded.cover_url,
                    local_path=excluded.local_path, updated_at=excluded.updated_at;
                """,
                [
                    .text(track.id), .text(track.title), .text(track.artist),
                    .text(track.album), .text(track.albumArtist), .integer(track.duration),
                    track.sourceURL.map(SQLiteValue.text) ?? .null,
                    track.coverURL.map(SQLiteValue.text) ?? .null,
                    .text(url.path),
                    .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
                ]
            )
        } catch {
            logger.error("Library import failed: \(error.localizedDescription)")
            return
        }
        tracks.insert(track, at: 0)
    }
}
