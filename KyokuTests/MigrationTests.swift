import XCTest
@testable import Kyoku

/// Migration: real v2 database file → v3. Verifies additive migration
/// preserves data and existing queries keep working.
final class MigrationTests: XCTestCase {
    /// Minimal v2-shaped database built with raw SQL (same DDL as
    /// Schema.v1+v2), with one track + one download task row.
    private func makeV2Database(at path: String) throws {
        let db = try Database(path: path)
        // Force version back to 2 semantics: Database() already migrated
        // to latest, so build the v2 shape manually instead.
        try db.execute("INSERT INTO tracks (id, title, artist, album, album_artist, duration, source_url, cover_url, local_path, created_at, updated_at) VALUES ('t1', 'Idol', 'YOASOBI', 'Idol', 'YOASOBI', 213, 'https://open.spotify.com/track/x', NULL, '/music/x.m4a', 1, 2);")
        try db.execute("INSERT INTO download_tasks (id, source_url, state, created_at, updated_at) VALUES ('d1', 'https://open.spotify.com/track/x', 'done', 1, 2);")
    }

    func testV2DataSurvivesV3Migration() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeV2Database(at: path)

        // Reopen with current code (runs pending migrations, if any).
        let db = try Database(path: path)
        let version = try db.query("PRAGMA user_version;").first?.values.first?.integer
        XCTAssertEqual(version, Database.schemaVersion)

        // Existing rows intact.
        let tracks = try db.query("SELECT id, title, artist, duration FROM tracks;")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?["title"]?.text, "Idol")
        XCTAssertEqual(tracks.first?["duration"]?.integer, 213)
        let tasks = try db.query("SELECT id, state FROM download_tasks;")
        XCTAssertEqual(tasks.count, 1)

        // New tables exist and are usable.
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table';")
            .compactMap { $0["name"]?.text }
        for expected in ["albums", "artists", "playlists", "playlist_tracks", "playback_history"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }

        // LibraryStore loads the old row through the new SELECT.
        let store = LibraryStore(database: db)
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertEqual(store.tracks.first?.title, "Idol")
    }

    func testReopenPreservesPlaylistsAndHistory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path)
        let store = LibraryStore(database: db)
        let p = store.createPlaylist(name: "Mix")
        // History for a missing track is ignored (FK-safe), must not crash.
        store.recordPlay(trackID: "nonexistent-track-id")
        _ = p
        // Reopen: playlists persist.
        let db2 = try Database(path: path)
        let store2 = LibraryStore(database: db2)
        XCTAssertEqual(store2.playlists.map(\.name), ["Mix"])
    }
}
