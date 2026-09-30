import XCTest
@testable import Kyoku

/// Change detection: the pure ChangeSet.diff function.
/// No I/O, no backend — the heart of sync correctness.
final class ChangeDetectionTests: XCTestCase {
    private func entry(_ key: String, title: String = "T", artist: String = "A",
                       album: String = "Al", duration: Int = 200) -> SnapshotEntry {
        SnapshotEntry(key: key, url: "https://open.spotify.com/track/\(key)",
                      title: title, artist: artist, album: album,
                      duration: duration, position: 0)
    }

    func testEmptyOldMeansAllAdded() {
        let changes = ChangeSet.diff(old: [], new: [entry("a"), entry("b")])
        XCTAssertEqual(changes.added.count, 2)
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertEqual(changes.unchangedCount, 0)
    }

    func testEmptyNewMeansAllRemoved() {
        let changes = ChangeSet.diff(old: [entry("a")], new: [])
        XCTAssertEqual(changes.removed.count, 1)
        XCTAssertTrue(changes.added.isEmpty)
    }

    func testIdenticalSyncIsNoOp() {
        let old = [entry("a"), entry("b")]
        let changes = ChangeSet.diff(old: old, new: old)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.unchangedCount, 2)
    }

    func testAddRemoveUnchanged() {
        let old = [entry("keep"), entry("gone")]
        let new = [entry("keep"), entry("fresh")]
        let changes = ChangeSet.diff(old: old, new: new)
        XCTAssertEqual(changes.added.map(\.key), ["fresh"])
        XCTAssertEqual(changes.removed.map(\.key), ["gone"])
        XCTAssertEqual(changes.unchangedCount, 1)
    }

    func testChangedMetadataDetected() {
        let old = [entry("a", title: "Old Title")]
        let new = [entry("a", title: "New Title")]
        let changes = ChangeSet.diff(old: old, new: new)
        XCTAssertEqual(changes.changed.count, 1)
        XCTAssertEqual(changes.changed.first?.old.title, "Old Title")
        XCTAssertEqual(changes.changed.first?.new.title, "New Title")
        XCTAssertTrue(changes.added.isEmpty && changes.removed.isEmpty)
    }

    func testDurationTolerance() {
        // ±2s (re-encodes, rounding) is not a change.
        let old = [entry("a", duration: 200)]
        let changes = ChangeSet.diff(old: old, new: [entry("a", duration: 202)])
        XCTAssertTrue(changes.isEmpty)
        let big = ChangeSet.diff(old: old, new: [entry("a", duration: 210)])
        XCTAssertEqual(big.changed.count, 1)
    }

    func testReorderAloneIsNoChange() {
        let old = [entry("a"), entry("b"), entry("c")]
        let changes = ChangeSet.diff(old: old, new: [entry("c"), entry("a"), entry("b")])
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.unchangedCount, 3)
    }

    func testDuplicateKeysDedupe() {
        let changes = ChangeSet.diff(old: [], new: [entry("a"), entry("a")])
        XCTAssertEqual(changes.added.count, 1)
    }

    func testSnapshotKeyPrefersURL() {
        let song = ResolvedSong(name: "Idol", artist: "YOASOBI", artists: ["YOASOBI"],
                                albumName: "Idol", albumArtist: "YOASOBI", duration: 213,
                                year: 2023, date: "2023-04-12", trackNumber: 1, discNumber: 1,
                                songID: "x", url: "https://open.spotify.com/track/X",
                                downloadURL: nil, coverURL: nil, isrc: nil, explicit: false,
                                lyrics: nil, listName: nil, listPosition: nil)
        XCTAssertEqual(SnapshotEntry.key(for: song, position: 0),
                       "url:https://open.spotify.com/track/x")
    }
}
