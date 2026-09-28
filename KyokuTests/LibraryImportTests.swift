import XCTest
@testable import Kyoku

/// Library ingestion: import, duplicate handling, normalization.
/// Uses a temp SQLite DB per test (real Database, real schema).
final class LibraryImportTests: XCTestCase {
    var dbPath: String!
    var db: Database!
    var store: LibraryStore!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        db = try! Database(path: dbPath)
        store = LibraryStore(database: db)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    private func song(
        name: String = "Idol", artist: String = "YOASOBI",
        album: String = "Idol", url: String = "https://open.spotify.com/track/abc"
    ) -> ResolvedSong {
        ResolvedSong(name: name, artist: artist, artists: [artist],
                     albumName: album, albumArtist: artist, duration: 213,
                     year: 2023, date: "2023-04-12", trackNumber: 1, discNumber: 1,
                     songID: "abc", url: url, downloadURL: nil,
                     coverURL: nil, isrc: nil, explicit: false,
                     lyrics: nil, listName: nil, listPosition: nil)
    }

    private func fakeAudio() -> URL {
        // Empty file: FileMetadataReader returns empty tags, provider wins.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    func testImportCreatesTrackWithProviderMetadata() throws {
        let url = fakeAudio()
        store.importFile(at: url, song: song())
        XCTAssertEqual(store.tracks.count, 1)
        let track = store.tracks[0]
        XCTAssertEqual(track.title, "Idol")
        XCTAssertEqual(track.artist, "YOASOBI")
        XCTAssertEqual(track.album, "Idol")
        XCTAssertEqual(track.duration, 213)
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.releaseDate, "2023-04-12")
        XCTAssertEqual(track.localPath, url.path)
    }

    func testDuplicateSourceURLReusesRow() throws {
        let url = fakeAudio()
        store.importFile(at: url, song: song())
        store.importFile(at: url, song: song())
        XCTAssertEqual(store.tracks.count, 1)
        let rows = try db.query("SELECT COUNT(*) AS c FROM tracks;")
        XCTAssertEqual(rows.first?["c"]?.integer, 1)
    }

    func testNormalizationMergesCaseVariants() throws {
        store.importFile(at: fakeAudio(), song: song(artist: "YOASOBI"))
        store.importFile(at: fakeAudio(), song: song(
            name: "Other", artist: "yoasobi ",
            url: "https://open.spotify.com/track/def"))
        let artists = try db.query("SELECT id, name FROM artists;")
        XCTAssertEqual(artists.count, 1, "case/whitespace variants must share one artist row")
        XCTAssertEqual(artists.first?["id"]?.text, "yoasobi")
    }

    func testAlbumIdentityIncludesArtist() throws {
        // Same album title, different artists → two album rows.
        store.importFile(at: fakeAudio(), song: song(album: "Hits", url: "https://open.spotify.com/track/1"))
        var other = song(album: "Hits", url: "https://open.spotify.com/track/2")
        other.artist = "Someone Else"
        other.artists = ["Someone Else"]
        other.albumArtist = "Someone Else"
        store.importFile(at: fakeAudio(), song: other)
        let albums = try db.query("SELECT COUNT(*) AS c FROM albums;")
        XCTAssertEqual(albums.first?["c"]?.integer, 2)
    }

    func testMissingFileReconcile() throws {
        let url = fakeAudio()
        store.importFile(at: url, song: song())
        XCTAssertEqual(store.tracks.count, 1)
        // Externally delete the file, reconcile must flag (not delete).
        try FileManager.default.removeItem(at: url)
        let missing = store.reconcile()
        XCTAssertEqual(missing, [store.tracks[0].id])
        XCTAssertEqual(store.tracks.count, 1, "reconcile never deletes rows")
    }

    func testPlaylistOrder() throws {
        let p = store.createPlaylist(name: "Mix")
        let t1 = fakeAudio(), t2 = fakeAudio(), t3 = fakeAudio()
        store.importFile(at: t1, song: song(name: "A", url: "https://open.spotify.com/track/1"))
        store.importFile(at: t2, song: song(name: "B", url: "https://open.spotify.com/track/2"))
        store.importFile(at: t3, song: song(name: "C", url: "https://open.spotify.com/track/3"))
        let ids = store.tracks.compactMap { t -> String? in
            ["A", "B", "C"].contains(t.title) ? t.id : nil
        }
        // Import order is newest-first in memory; resolve by title.
        func id(named n: String) -> String {
            store.tracks.first { $0.title == n }!.id
        }
        store.addToPlaylist(playlistID: p.id, trackIDs: [id(named: "A"), id(named: "B"), id(named: "C")])
        XCTAssertEqual(store.playlistTracks(id: p.id).map(\.title), ["A", "B", "C"])
        store.reorderPlaylist(playlistID: p.id, orderedTrackIDs: [id(named: "C"), id(named: "A"), id(named: "B")])
        XCTAssertEqual(store.playlistTracks(id: p.id).map(\.title), ["C", "A", "B"])
        store.removeFromPlaylist(playlistID: p.id, trackID: id(named: "A"))
        XCTAssertEqual(store.playlistTracks(id: p.id).map(\.title), ["C", "B"])
        _ = ids
    }
}
