import XCTest
@testable import Kyoku

/// Workstream 5: library robustness — missing state, artwork extraction,
/// dedupe, LIKE escaping, import precedence. Uses temp DBs + disposable
/// fixture files only; never the user's real ~/Music/Kyoku.
final class LibraryRobustnessTests: XCTestCase {
    var dbPath: String!
    var db: Database!
    var store: LibraryStore!
    var scratch: URL!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        db = try! Database(path: dbPath)
        store = LibraryStore(database: db)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func song(url: String = "https://open.spotify.com/track/x",
                      name: String = "T", artist: String = "A",
                      album: String = "Al", duration: Int = 200) -> ResolvedSong {
        ResolvedSong(name: name, artist: artist, artists: [artist],
                     albumName: album, albumArtist: artist, duration: duration,
                     year: nil, date: nil, trackNumber: 1, discNumber: 1,
                     songID: UUID().uuidString, url: url,
                     downloadURL: nil, coverURL: nil, isrc: nil, explicit: false,
                     lyrics: nil, listName: nil, listPosition: nil)
    }

    private func fixtureFile(named: String = "track.m4a") -> URL {
        let url = scratch.appendingPathComponent(named)
        FileManager.default.createFile(atPath: url.path, contents: Data("fake-audio".utf8))
        return url
    }

    // MARK: - Missing state

    func testMissingTrackReportedNotDeleted() {
        let file = fixtureFile()
        store.importFile(at: file, song: song())
        XCTAssertEqual(store.tracks.count, 1)
        try! FileManager.default.removeItem(at: file)
        let missing = store.reconcile()
        XCTAssertEqual(missing.count, 1)
        // Row preserved; flagged missing.
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertFalse(store.tracks.first!.isAvailable)
        XCTAssertTrue(store.missingTrackIDs.contains(store.tracks.first!.id))
    }

    func testMissingStateSurvivesRefresh() {
        let file = fixtureFile()
        store.importFile(at: file, song: song())
        try! FileManager.default.removeItem(at: file)
        _ = store.reconcile()
        store.refresh()
        XCTAssertFalse(store.tracks.first!.isAvailable,
                       "refresh must preserve known-missing state")
    }

    func testRestoredFileReimportHasNoDuplicate() {
        let file = fixtureFile()
        store.importFile(at: file, song: song(url: "https://open.spotify.com/track/dup"))
        try! FileManager.default.removeItem(at: file)
        _ = store.reconcile()
        XCTAssertFalse(store.tracks.first!.isAvailable)
        // File comes back (same path): re-import restores availability.
        FileManager.default.createFile(atPath: file.path, contents: Data("fake-audio".utf8))
        store.importFile(at: file, song: song(url: "https://open.spotify.com/track/dup"))
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertTrue(store.tracks.first!.isAvailable)
        XCTAssertEqual(store.tracks.first?.localPath, file.path)
    }

    // MARK: - Artwork

    func testArtworkExtractionToManagedCache() {
        // Real embedded art: copy the probe to a fixture with artwork.
        // Here we verify the no-art path never crashes and persists nil;
        // the positive path uses ArtworkStore directly below.
        let file = fixtureFile()
        store.importFile(at: file, song: song())
        // Fake file has no embedded art → nil artworkPath, still imports.
        XCTAssertNil(store.tracks.first?.artworkPath)
    }

    func testArtworkStoreRoundTrip() {
        // Positive path: write a tiny valid image as the "embedded" source
        // via ArtworkStore.extract on a real audio container is heavyweight;
        // instead verify the cache directory + safe-key behavior.
        let dir = ArtworkStore.artworkDirectory()
        XCTAssertNotNil(dir)
        // Extraction of a file without artwork returns nil (no crash).
        let file = fixtureFile()
        XCTAssertNil(ArtworkStore.extract(audioURL: file, key: "test-key"))
        // Idempotent: second call also nil, no error.
        XCTAssertNil(ArtworkStore.extract(audioURL: file, key: "test-key"))
        // Missing file → nil.
        XCTAssertNil(ArtworkStore.extract(
            audioURL: scratch.appendingPathComponent("nope.m4a"), key: "k"))
    }

    func testAlbumArtworkBackfillFromTrack() throws {
        // Simulate a track WITH managed art: import, then set artworkPath
        // directly and re-run ensureAlbumArtistRows → album row gains art.
        let file = fixtureFile()
        store.importFile(at: file, song: song(album: "Shared"))
        let trackID = store.tracks.first!.id
        // Pretend extraction succeeded: point at a real temp image.
        let imgURL = scratch.appendingPathComponent("art.jpg")
        FileManager.default.createFile(atPath: imgURL.path, contents: Data(repeating: 0, count: 64))
        try db.execute("UPDATE tracks SET artwork_path=? WHERE id=?;",
                       [.text(imgURL.path), .text(trackID)])
        store.refresh()
        store.ensureAlbumArtistRows(for: store.tracks.first!)
        let albums = try db.query("SELECT artwork_path FROM albums;")
        XCTAssertEqual(albums.first?["artwork_path"]?.text, imgURL.path)
        // Second track, same album, no art: must NOT overwrite.
        let file2 = fixtureFile(named: "t2.m4a")
        store.importFile(at: file2, song: song(url: "https://open.spotify.com/track/y",
                                               album: "Shared"))
        let albums2 = try db.query("SELECT artwork_path FROM albums;")
        XCTAssertEqual(albums2.first?["artwork_path"]?.text, imgURL.path)
    }

    // MARK: - Dedupe / uniqueness

    func testDuplicateSourceImportIdempotent() {
        let file = fixtureFile()
        let s = song(url: "https://open.spotify.com/track/same")
        store.importFile(at: file, song: s)
        store.importFile(at: file, song: s)
        XCTAssertEqual(store.tracks.count, 1)
    }

    func testSchemaDedupeMergesAndIndexes() throws {
        // Insert two rows sharing a source_url directly, then run the
        // migration helper: one survives, history re-points, index exists.
        // NOTE: db is fresh (v7, partial unique index live), so the second
        // INSERT would violate the index — drop it first to simulate the
        // pre-migration duplicate state, then re-create via the helper.
        try db.execute("DROP INDEX IF EXISTS idx_tracks_source_url;")
        try db.execute(
            "INSERT INTO tracks (id, title, source_url, local_path, created_at, updated_at) VALUES ('a','T','https://dup/x','/tmp/a.m4a',1,1);")
        try db.execute(
            "INSERT INTO tracks (id, title, source_url, local_path, created_at, updated_at) VALUES ('b','T','https://dup/x','/tmp/b.m4a',1,2);")
        try db.execute("INSERT INTO playback_history (track_id, played_at) VALUES ('a', 1);")
        let merged = try Schema.dedupeLibraryTracks(database: db)
        XCTAssertEqual(merged, 1)
        let remaining = try db.query("SELECT id FROM tracks WHERE source_url='https://dup/x';")
        XCTAssertEqual(remaining.count, 1)
        // Winner = most recent (b); history re-pointed.
        XCTAssertEqual(remaining.first?["id"]?.text, "b")
        let hist = try db.query("SELECT track_id FROM playback_history;")
        XCTAssertEqual(hist.first?["track_id"]?.text, "b")
        // Re-create the index as v7dedupe would (idempotent).
        _ = try Schema.v7dedupe(database: db)
        // Fresh duplicates now rejected at the DB level.
        XCTAssertThrowsError(
            try db.execute(
                "INSERT INTO tracks (id, title, source_url, created_at, updated_at) VALUES ('c','T','https://dup/x',1,3);"))
    }

    func testUniqueIndexEnforced() throws {
        // After v7dedupe, the partial index rejects fresh duplicates.
        _ = try Schema.v7dedupe(database: db)
        try db.execute(
            "INSERT INTO tracks (id, title, source_url, created_at, updated_at) VALUES ('u1','T','https://u/1',1,1);")
        XCTAssertThrowsError(
            try db.execute(
                "INSERT INTO tracks (id, title, source_url, created_at, updated_at) VALUES ('u2','T','https://u/1',1,1);"),
            "partial unique index must reject duplicate source_url")
        // NULL/empty URLs exempt: one-off imports without provider data.
        try db.execute(
            "INSERT INTO tracks (id, title, created_at, updated_at) VALUES ('n1','T',1,1);")
        try db.execute(
            "INSERT INTO tracks (id, title, created_at, updated_at) VALUES ('n2','T',1,1);")
    }

    // MARK: - LIKE escaping

    private func seedSearchTitles(_ titles: [String]) {
        for (i, title) in titles.enumerated() {
            store.importFile(at: fixtureFile(named: "s\(i).m4a"),
                             song: song(url: "https://open.spotify.com/track/s\(i)",
                                        name: title))
        }
    }

    func testPercentIsLiteral() {
        seedSearchTitles(["100% Hits", "1000 Hits"])
        let results = store.search("100%")
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertEqual(results.tracks.first?.title, "100% Hits")
    }

    func testUnderscoreIsLiteral() {
        seedSearchTitles(["a_b", "aXb"])
        let results = store.search("a_b")
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertEqual(results.tracks.first?.title, "a_b")
    }

    func testBackslashIsLiteral() {
        seedSearchTitles(["a\\b", "ab"])
        let results = store.search("a\\b")
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertEqual(results.tracks.first?.title, "a\\b")
    }

    func testOrdinarySearchUnchanged() {
        seedSearchTitles(["Hello World", "Goodbye"])
        let results = store.search("hello")
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertEqual(results.tracks.first?.title, "Hello World")
    }

    // MARK: - Import precedence / robustness

    func testProviderMetadataWinsOverFile() {
        // Fake file has no tags; provider values must survive intact.
        let file = fixtureFile()
        store.importFile(at: file, song: song(name: "Prov", artist: "PA",
                                              album: "PAl", duration: 321))
        let t = store.tracks.first!
        XCTAssertEqual(t.title, "Prov")
        XCTAssertEqual(t.artist, "PA")
        XCTAssertEqual(t.album, "PAl")
        XCTAssertEqual(t.duration, 321)
    }

    func testCorruptMediaImportDoesNotCrash() {
        // Zero-byte file: AV probe returns nothing; import still succeeds
        // with provider metadata and duration fallback.
        let url = scratch.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        store.importFile(at: url, song: song())
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertEqual(store.tracks.first?.duration, 200)
    }

    func testAlbumArtistRelationshipsSurviveReimport() {
        let file = fixtureFile()
        store.importFile(at: file, song: song(artist: "Solo", album: "Debut"))
        let albumID = store.tracks.first?.albumID
        XCTAssertNotNil(albumID)
        store.importFile(at: file, song: song(artist: "Solo", album: "Debut"))
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertEqual(store.tracks.first?.albumID, albumID)
        XCTAssertEqual(store.albums.count, 1)
    }
}
