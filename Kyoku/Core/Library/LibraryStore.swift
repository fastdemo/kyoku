import Combine
import Foundation

/// Persistent, observable library index. Database-backed.
///
/// Phase 2: normalized albums/artists/playlists, explicit reconcile(),
/// DB-backed search, Recently Added/Played queries, artwork resolution
/// (cached file → embedded → placeholder, decided by views).
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var playlists: [Playlist] = []

    /// Track IDs whose localPath is currently missing on disk.
    /// Updated by reconcile(); views dim these instead of hiding them.
    @Published private(set) var missingTrackIDs: Set<String> = []

    private let database: Database
    private let logger = KyokuLogger(subsystem: "core", category: "library")

    /// Cap for in-memory lists. DB remains authoritative; views page
    /// through search()/recentlyAdded() for more. 5000 covers realistic
    /// libraries without a paged UI yet (Phase 3+ if needed).
    private let listLimit = 5000

    private static let trackColumns = """
        id, title, artist, album, album_artist, track_number, disc_number,
        genre, duration, release_date, source_url, cover_url, artwork_path,
        local_path, play_count, last_played_at, album_id, artist_id,
        created_at, updated_at
        """

    init(database: Database) {
        self.database = database
        refresh()
    }

    // MARK: - Loading

    func refresh() {
        tracks = loadTracks(sql: "SELECT \(Self.trackColumns) FROM tracks ORDER BY created_at DESC LIMIT \(listLimit);")
        // Availability is filesystem truth, recomputed by reconcile() and
        // maintained by importFile/removeFromLibrary. New rows default to
        // available (Track.isAvailable initial value). Preserve flags for
        // still-missing IDs so a plain refresh doesn't resurrect them.
        let knownMissing = missingTrackIDs
        for i in tracks.indices where knownMissing.contains(tracks[i].id) {
            // Only keep the flag when the file is STILL missing (import may
            // have revived the row and already cleared the flag — see
            // importFile revive path; this guard makes refresh idempotent).
            if let path = tracks[i].localPath,
               !FileManager.default.fileExists(atPath: path) {
                tracks[i].isAvailable = false
            }
        }
        albums = loadAlbums()
        artists = loadArtists()
        playlists = loadPlaylists()
    }

    private func loadTracks(sql: String, args: [SQLiteValue] = []) -> [Track] {
        do {
            return try database.query(sql, args).compactMap(Self.makeTrack)
        } catch {
            logger.error("Library load failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func makeTrack(_ row: [String: SQLiteValue]) -> Track? {
        guard let id = row["id"]?.text,
              let title = row["title"]?.text
        else { return nil }
        let track = Track(
            id: id,
            title: title,
            artist: row["artist"]?.text ?? "",
            album: row["album"]?.text ?? "",
            albumArtist: row["album_artist"]?.text ?? "",
            trackNumber: row["track_number"]?.integer ?? 0,
            discNumber: row["disc_number"]?.integer ?? 0,
            genre: row["genre"]?.text,
            duration: row["duration"]?.integer ?? 0,
            releaseDate: row["release_date"]?.text,
            sourceURL: row["source_url"]?.text,
            coverURL: row["cover_url"]?.text,
            artworkPath: row["artwork_path"]?.text,
            localPath: row["local_path"]?.text,
            playCount: row["play_count"]?.integer ?? 0,
            lastPlayedAt: row["last_played_at"]?.real.map(Date.init(timeIntervalSince1970:)),
            albumID: row["album_id"]?.text,
            artistID: row["artist_id"]?.text,
            createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
            updatedAt: row["updated_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
        )
        return track
    }

    private func loadAlbums() -> [Album] {
        do {
            return try database.query(
                "SELECT id, title, artist, artwork_path, release_date FROM albums ORDER BY title;"
            ).compactMap { row in
                guard let id = row["id"]?.text, let title = row["title"]?.text else { return nil }
                return Album(id: id, title: title, artist: row["artist"]?.text ?? "",
                             artworkPath: row["artwork_path"]?.text,
                             releaseDate: row["release_date"]?.text)
            }
        } catch {
            logger.error("Albums load failed: \(error.localizedDescription)")
            return []
        }
    }

    private func loadArtists() -> [Artist] {
        do {
            return try database.query(
                "SELECT id, name, artwork_path FROM artists ORDER BY name;"
            ).compactMap { row in
                guard let id = row["id"]?.text, let name = row["name"]?.text else { return nil }
                return Artist(id: id, name: name, artworkPath: row["artwork_path"]?.text)
            }
        } catch {
            logger.error("Artists load failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Ingestion (primary entry point, called by DownloadQueue)

    /// Index a freshly downloaded file.
    ///
    /// Metadata precedence (deliberate, field by field):
    /// 1. ResolvedSong for all text metadata (title/artist/album/…).
    /// 2. File tags fill `duration` only when the provider reports <= 0.
    /// 3. Album/artist rows are ensured (normalized identity) and linked.
    ///
    /// Duplicate imports of the same source URL reuse the existing track
    /// row (path + metadata updated) instead of creating a second row.
    func importFile(at url: URL, song: ResolvedSong?) {
        let now = Date()
        // NOTE: FileMetadataReader uses AVURLAsset (main-thread-hostile in
        // some sandbox/test contexts). Callers on the worker path are
        // already off the render path; keep duration cheap: prefer provider
        // metadata, probe the file only when the provider reports nothing.
        let duration: Int
        if let song, song.duration > 0 {
            duration = song.duration
        } else {
            duration = FileMetadataReader.read(url: url).duration
        }

        // Duplicate detection: same Spotify source URL → same track.
        // A missing row with the same source URL is REVIVED (not
        // duplicated): the file came back, so restore availability +
        // path on the existing row. Only available rows skip re-import.
        if let sourceURL = song?.url,
           let existing = tracks.first(where: { $0.sourceURL == sourceURL }) {
            // Fresh import of an already-available track: nothing to do
            // (metadata refresh is a later phase; keep it idempotent).
            if existing.isAvailable, existing.localPath == url.path {
                return
            }
            var updated = existing
            updated.localPath = url.path
            updated.isAvailable = true
            // A restored file may carry new embedded art (re-encode,
            // re-download). Refresh the managed cache when missing.
            if updated.artworkPath == nil,
               let cached = ArtworkStore.extract(audioURL: url, key: existing.id) {
                updated.artworkPath = cached
            }
            updated.updatedAt = now
            if updated.duration <= 0 { updated.duration = duration }
            persistTrack(updated, insertIfMissing: true)
            ensureAlbumArtistRows(for: updated)
            // Revived: drop the stale missing flag so refresh() (below)
            // and views read available. reconcile() re-derives from disk.
            missingTrackIDs.remove(existing.id)
            refresh()
            return
        }

        var track = song?.asTrack(localPath: url.path, now: now) ?? Track(
            title: url.deletingPathExtension().lastPathComponent,
            localPath: url.path, createdAt: now, updatedAt: now
        )
        track.duration = duration
        // Managed artwork: extract embedded art once at import (background
        // worker context), so cells never parse media to render. Provider
        // metadata stays authoritative for text; artwork is additive only.
        if let cached = ArtworkStore.extract(audioURL: url, key: track.id) {
            track.artworkPath = cached
        }
        track.isAvailable = true
        persistTrack(track, insertIfMissing: true)
        ensureAlbumArtistRows(for: track)
        refresh()
    }

    private func persistTrack(_ track: Track, insertIfMissing: Bool) {
        let verb = insertIfMissing
            ? "INSERT INTO tracks (id, title, artist, album, album_artist, track_number, disc_number, genre, duration, release_date, source_url, cover_url, artwork_path, local_path, play_count, last_played_at, album_id, artist_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET"
            : "UPDATE tracks SET"
        // Single upsert statement keeps both paths identical.
        _ = verb
        do {
            try database.execute(
                """
                INSERT INTO tracks (id, title, artist, album, album_artist, track_number, disc_number, genre, duration, release_date, source_url, cover_url, artwork_path, local_path, play_count, last_played_at, album_id, artist_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, artist=excluded.artist, album=excluded.album,
                    album_artist=excluded.album_artist, track_number=excluded.track_number,
                    disc_number=excluded.disc_number, genre=excluded.genre,
                    duration=excluded.duration, release_date=excluded.release_date,
                    source_url=excluded.source_url, cover_url=excluded.cover_url,
                    artwork_path=excluded.artwork_path, local_path=excluded.local_path,
                    play_count=excluded.play_count, last_played_at=excluded.last_played_at,
                    album_id=excluded.album_id, artist_id=excluded.artist_id,
                    updated_at=excluded.updated_at;
                """,
                [
                    .text(track.id), .text(track.title), .text(track.artist),
                    .text(track.album), .text(track.albumArtist),
                    .integer(track.trackNumber), .integer(track.discNumber),
                    track.genre.map(SQLiteValue.text) ?? .null,
                    .integer(track.duration),
                    track.releaseDate.map(SQLiteValue.text) ?? .null,
                    track.sourceURL.map(SQLiteValue.text) ?? .null,
                    track.coverURL.map(SQLiteValue.text) ?? .null,
                    track.artworkPath.map(SQLiteValue.text) ?? .null,
                    track.localPath.map(SQLiteValue.text) ?? .null,
                    .integer(track.playCount),
                    track.lastPlayedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    track.albumID.map(SQLiteValue.text) ?? .null,
                    track.artistID.map(SQLiteValue.text) ?? .null,
                    .real(track.createdAt.timeIntervalSince1970),
                    .real(track.updatedAt.timeIntervalSince1970),
                ]
            )
        } catch {
            logger.error("Library import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Album / artist normalization

    /// Ensure normalized rows exist for a track's album + artist, link the
    /// track, and backfill display spellings on first sight. Blank names
    /// are skipped (no "" rows).
    func ensureAlbumArtistRows(for track: Track) {
        let now = Date().timeIntervalSince1970
        // Artist (track artist).
        let artistName = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artistName.isEmpty {
            let artistID = LibraryIdentity.canonical(artistName)
            do {
                try database.execute(
                    "INSERT INTO artists (id, name, created_at, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING;",
                    [.text(artistID), .text(artistName), .real(now), .real(now)]
                )
                try database.execute("UPDATE tracks SET artist_id=? WHERE id=?;",
                                     [.text(artistID), .text(track.id)])
            } catch {
                logger.error("Artist link failed: \(error.localizedDescription)")
            }
        }
        // Album (title + effective artist).
        let albumTitle = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !albumTitle.isEmpty {
            let effectiveArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            let albumID = LibraryIdentity.albumID(
                title: albumTitle, albumArtist: track.albumArtist, artist: track.artist)
            do {
                try database.execute(
                    "INSERT INTO albums (id, title, artist, release_date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING;",
                    [.text(albumID), .text(albumTitle), .text(effectiveArtist),
                     track.releaseDate.map(SQLiteValue.text) ?? .null,
                     .real(now), .real(now)]
                )
                try database.execute("UPDATE tracks SET album_id=? WHERE id=?;",
                                     [.text(albumID), .text(track.id)])
                // Album artwork backfill: first track with managed art wins.
                // Reuses the track's extracted file (no re-extraction, no
                // per-cell parsing). Later tracks never overwrite.
                if let art = track.artworkPath {
                    try database.execute(
                        "UPDATE albums SET artwork_path=? WHERE id=? AND (artwork_path IS NULL OR artwork_path='');",
                        [.text(art), .text(albumID)]
                    )
                }
            } catch {
                logger.error("Album link failed: \(error.localizedDescription)")
            }
        }
    }

    /// Backfill normalized rows for tracks imported before v3.
    func backfillAlbumArtistRows() {
        for track in tracks {
            if track.artistID == nil || track.albumID == nil {
                ensureAlbumArtistRows(for: track)
            }
        }
        refresh()
    }

    // MARK: - Reconciliation (explicit, not a watcher)

    /// Check every track's file on disk. Returns missing IDs and publishes
    /// them; rows are NOT deleted (user decides: relink or remove).
    /// Safe on missing drives: everything simply reports missing.
    /// Also hydrates per-track `isAvailable` so views render missing state
    /// without their own filesystem checks.
    @discardableResult
    func reconcile() -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for i in tracks.indices {
            guard let path = tracks[i].localPath else { continue }
            let available = fm.fileExists(atPath: path)
            tracks[i].isAvailable = available
            if !available {
                missing.append(tracks[i].id)
            }
        }
        missingTrackIDs = Set(missing)
        if !missing.isEmpty {
            logger.info("Reconcile: \(missing.count) of \(tracks.count) tracks missing on disk.")
        }
        return missing
    }

    // MARK: - Library mutations

    /// Remove a track from the library index. Keeps the file on disk.
    func removeFromLibrary(trackID: String) {
        do {
            try database.execute("DELETE FROM tracks WHERE id=?;", [.text(trackID)])
        } catch {
            logger.error("Remove failed: \(error.localizedDescription)")
            return
        }
        tracks.removeAll { $0.id == trackID }
        missingTrackIDs.remove(trackID)
    }

    /// Remove the track AND delete its file. Requires explicit user
    /// confirmation in the view; returns false when nothing was deleted.
    @discardableResult
    func deleteFile(trackID: String) -> Bool {
        guard let track = tracks.first(where: { $0.id == trackID }),
              let path = track.localPath
        else { return false }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            logger.error("Trash failed: \(error.localizedDescription)")
            return false
        }
        removeFromLibrary(trackID: trackID)
        return true
    }

    // MARK: - Queries (DB-backed, not in-memory filters)

    func recentlyAdded(limit: Int = 100) -> [Track] {
        loadTracks(sql: "SELECT \(Self.trackColumns) FROM tracks ORDER BY created_at DESC LIMIT ?;",
                   args: [.integer(limit)])
    }

    func recentlyPlayed(limit: Int = 100) -> [Track] {
        loadTracks(sql: """
            SELECT \(Self.trackColumns) FROM tracks
            WHERE last_played_at IS NOT NULL
            ORDER BY last_played_at DESC LIMIT ?;
            """, args: [.integer(limit)])
    }

    func tracksForAlbum(id: String) -> [Track] {
        loadTracks(sql: "SELECT \(Self.trackColumns) FROM tracks WHERE album_id=? ORDER BY disc_number, track_number, title;",
                   args: [.text(id)])
    }

    func albumsForArtist(id: String) -> [Album] {
        // Albums whose canonical artist matches, via tracks linkage.
        do {
            let artistName: String? = try database.query(
                "SELECT name FROM artists WHERE id=?;", [.text(id)]
            ).first?["name"]?.text
            guard let artistName else { return [] }
            let canon = LibraryIdentity.canonical(artistName)
            return try database.query(
                "SELECT id, title, artist, artwork_path, release_date FROM albums;"
            ).compactMap { row in
                guard let aid = row["id"]?.text, let title = row["title"]?.text else { return nil }
                let aArtist = row["artist"]?.text ?? ""
                guard LibraryIdentity.canonical(aArtist) == canon else { return nil }
                return Album(id: aid, title: title, artist: aArtist,
                             artworkPath: row["artwork_path"]?.text,
                             releaseDate: row["release_date"]?.text)
            }
        } catch {
            logger.error("Albums-for-artist failed: \(error.localizedDescription)")
            return []
        }
    }

    func tracksForArtist(id: String) -> [Track] {
        loadTracks(sql: "SELECT \(Self.trackColumns) FROM tracks WHERE artist_id=? ORDER BY album, disc_number, track_number;",
                   args: [.text(id)])
    }

    struct SearchResults: Sendable {
        var tracks: [Track] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
    }

    /// Local LIKE search across tracks/albums/artists/playlists.
    /// Escapes %, _, and \ so user text is always literal (backslash is
    /// the ESCAPE character and must itself be escaped first).
    func search(_ raw: String, limitPerSection: Int = 25) -> SearchResults {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResults() }
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var out = SearchResults()
        out.tracks = loadTracks(sql: """
            SELECT \(Self.trackColumns) FROM tracks
            WHERE title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\'
            ORDER BY artist, album, track_number LIMIT ?;
            """, args: [.text(like), .text(like), .text(like), .integer(limitPerSection)])
        do {
            out.albums = try database.query(
                "SELECT id, title, artist, artwork_path, release_date FROM albums WHERE title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' ORDER BY title LIMIT ?;",
                [.text(like), .text(like), .integer(limitPerSection)]
            ).compactMap { row in
                guard let id = row["id"]?.text, let title = row["title"]?.text else { return nil }
                return Album(id: id, title: title, artist: row["artist"]?.text ?? "",
                             artworkPath: row["artwork_path"]?.text,
                             releaseDate: row["release_date"]?.text)
            }
            out.artists = try database.query(
                "SELECT id, name, artwork_path FROM artists WHERE name LIKE ? ESCAPE '\\' ORDER BY name LIMIT ?;",
                [.text(like), .integer(limitPerSection)]
            ).compactMap { row in
                guard let id = row["id"]?.text, let name = row["name"]?.text else { return nil }
                return Artist(id: id, name: name, artworkPath: row["artwork_path"]?.text)
            }
            out.playlists = try database.query(
                "SELECT id, name, created_at, updated_at FROM playlists WHERE name LIKE ? ESCAPE '\\' ORDER BY name LIMIT ?;",
                [.text(like), .integer(limitPerSection)]
            ).compactMap(Self.makePlaylist)
        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
        }
        return out
    }

    // MARK: - Playlists

    private static func makePlaylist(_ row: [String: SQLiteValue]) -> Playlist? {
        guard let id = row["id"]?.text, let name = row["name"]?.text else { return nil }
        return Playlist(
            id: id, name: name,
            createdAt: row["created_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date(),
            updatedAt: row["updated_at"]?.real.map(Date.init(timeIntervalSince1970:)) ?? Date()
        )
    }

    private func loadPlaylists() -> [Playlist] {
        do {
            return try database.query(
                "SELECT id, name, created_at, updated_at FROM playlists ORDER BY name;"
            ).compactMap(Self.makePlaylist)
        } catch {
            logger.error("Playlists load failed: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Playlist" : name)
        do {
            try database.execute(
                "INSERT INTO playlists (id, name, created_at, updated_at) VALUES (?, ?, ?, ?);",
                [.text(playlist.id), .text(playlist.name),
                 .real(playlist.createdAt.timeIntervalSince1970),
                 .real(playlist.updatedAt.timeIntervalSince1970)]
            )
        } catch {
            logger.error("Playlist create failed: \(error.localizedDescription)")
        }
        playlists = loadPlaylists()
        return playlist
    }

    func renamePlaylist(id: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try database.execute("UPDATE playlists SET name=?, updated_at=? WHERE id=?;",
                                 [.text(clean), .real(Date().timeIntervalSince1970), .text(id)])
        } catch {
            logger.error("Playlist rename failed: \(error.localizedDescription)")
            return
        }
        playlists = loadPlaylists()
    }

    func deletePlaylist(id: String) {
        do {
            // Explicit deletes; CASCADE would also work but be explicit.
            try database.execute("DELETE FROM playlist_tracks WHERE playlist_id=?;", [.text(id)])
            try database.execute("DELETE FROM playlists WHERE id=?;", [.text(id)])
        } catch {
            logger.error("Playlist delete failed: \(error.localizedDescription)")
            return
        }
        playlists = loadPlaylists()
    }

    /// Ordered tracks for a playlist. Joins tracks so one query suffices.
    func playlistTracks(id: String) -> [Track] {
        loadTracks(sql: """
            SELECT \(Self.trackColumns) FROM tracks
            JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
            WHERE playlist_tracks.playlist_id = ?
            ORDER BY playlist_tracks.position;
            """, args: [.text(id)])
    }

    func addToPlaylist(playlistID: String, trackIDs: [String]) {
        do {
            var position = (try database.query(
                "SELECT MAX(position) AS m FROM playlist_tracks WHERE playlist_id=?;",
                [.text(playlistID)]
            ).first?["m"]?.integer) ?? -1
            for trackID in trackIDs {
                position += 1
                // INSERT OR IGNORE: same track twice keeps first position.
                try database.execute(
                    "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?);",
                    [.text(playlistID), .text(trackID), .integer(position)]
                )
            }
            try database.execute("UPDATE playlists SET updated_at=? WHERE id=?;",
                                 [.real(Date().timeIntervalSince1970), .text(playlistID)])
        } catch {
            logger.error("Add-to-playlist failed: \(error.localizedDescription)")
        }
    }

    func removeFromPlaylist(playlistID: String, trackID: String) {
        do {
            try database.execute(
                "DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?;",
                [.text(playlistID), .text(trackID)])
            normalizePlaylistPositions(playlistID: playlistID)
        } catch {
            logger.error("Remove-from-playlist failed: \(error.localizedDescription)")
        }
    }

    /// Persist a full reorder (drag-and-drop). IDs must be the complete
    /// ordered membership; positions are rewritten 0..n.
    func reorderPlaylist(playlistID: String, orderedTrackIDs: [String]) {
        do {
            for (index, trackID) in orderedTrackIDs.enumerated() {
                try database.execute(
                    "UPDATE playlist_tracks SET position=? WHERE playlist_id=? AND track_id=?;",
                    [.integer(index), .text(playlistID), .text(trackID)])
            }
            try database.execute("UPDATE playlists SET updated_at=? WHERE id=?;",
                                 [.real(Date().timeIntervalSince1970), .text(playlistID)])
        } catch {
            logger.error("Playlist reorder failed: \(error.localizedDescription)")
        }
    }

    private func normalizePlaylistPositions(playlistID: String) {
        do {
            let rows = try database.query(
                "SELECT track_id FROM playlist_tracks WHERE playlist_id=? ORDER BY position;",
                [.text(playlistID)])
            for (index, row) in rows.enumerated() {
                guard let trackID = row["track_id"]?.text else { continue }
                try database.execute(
                    "UPDATE playlist_tracks SET position=? WHERE playlist_id=? AND track_id=?;",
                    [.integer(index), .text(playlistID), .text(trackID)])
            }
        } catch {
            logger.error("Position normalize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback history

    /// Record one play: bump count + stamp + history row.
    /// History insert uses INSERT OR IGNORE so plays for tracks removed
    /// from the library don't fail on the FK (the counters update only
    /// when the row exists).
    func recordPlay(trackID: String, at date: Date = Date()) {
        do {
            try database.execute("INSERT OR IGNORE INTO playback_history (track_id, played_at) VALUES (?, ?);",
                                 [.text(trackID), .real(date.timeIntervalSince1970)])
            try database.execute(
                "UPDATE tracks SET play_count = play_count + 1, last_played_at=?, updated_at=? WHERE id=?;",
                [.real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970), .text(trackID)])
        } catch {
            logger.error("Record play failed: \(error.localizedDescription)")
            return
        }
        if let index = tracks.firstIndex(where: { $0.id == trackID }) {
            tracks[index].playCount += 1
            tracks[index].lastPlayedAt = date
        }
    }
}
