import AVFoundation
import XCTest
@testable import Kyoku

/// Playback queue semantics without audio hardware: ordering, shuffle,
/// repeat, missing-file skip. AVPlayer itself is exercised in-app.
final class PlaybackQueueTests: XCTestCase {
    /// Test tracks point at a shared silent audio fixture so AVPlayer can
    /// actually load them (empty files fail AVPlayerItem status and the
    /// missing-file skip would engage). Generated once per run.
    static var fixtureURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kyoku-test-tone.m4a")
        if !FileManager.default.fileExists(atPath: url.path) {
            // 0.5s silent AAC via AVFoundation.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
            ]
            guard let writer = try? AVAudioFile(forWriting: url, settings: settings) else {
                FileManager.default.createFile(atPath: url.path, contents: Data())
                return url
            }
            let format = writer.processingFormat
            let frames = AVAudioFrameCount(22050)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                buffer.frameLength = frames
                try? writer.write(from: buffer)
            }
        }
        return url
    }()

    func makeTrack(title: String) -> Track {
        Track(title: title, duration: 60, localPath: Self.fixtureURL.path)
    }

    @MainActor
    func testPlayTracksStartsAtIndex() {
        let svc = PlaybackService()
        let tracks = [makeTrack(title: "A"), makeTrack(title: "B"), makeTrack(title: "C")]
        svc.playTracks(tracks, startingAt: 1)
        XCTAssertEqual(svc.currentTrack?.title, "B")
        XCTAssertEqual(svc.queue.count, 3)
    }

    @MainActor
    func testNextPrevious() {
        let svc = PlaybackService()
        let tracks = [makeTrack(title: "A"), makeTrack(title: "B"), makeTrack(title: "C")]
        svc.playTracks(tracks, startingAt: 0)
        svc.next()
        XCTAssertEqual(svc.currentTrack?.title, "B")
        svc.previous() // >3s rule doesn't apply (time=0) → goes back
        XCTAssertEqual(svc.currentTrack?.title, "A")
    }

    @MainActor
    func testRepeatOneRestartsTrack() {
        let svc = PlaybackService()
        let tracks = [makeTrack(title: "A"), makeTrack(title: "B")]
        svc.playTracks(tracks, startingAt: 0)
        svc.repeatMode = .one
        svc.next(auto: true)
        XCTAssertEqual(svc.currentTrack?.title, "A", "repeat-one auto-advance restarts")
    }

    @MainActor
    func testRepeatAllWraps() {
        let svc = PlaybackService()
        let tracks = [makeTrack(title: "A"), makeTrack(title: "B")]
        svc.playTracks(tracks, startingAt: 1)
        svc.repeatMode = .all
        svc.next(auto: true)
        XCTAssertEqual(svc.currentTrack?.title, "A", "repeat-all wraps at end")
    }

    @MainActor
    func testMissingFileSkipsToNext() {
        let svc = PlaybackService()
        let good1 = makeTrack(title: "Good1")
        let missing = Track(title: "Missing", localPath: "/nonexistent/xyz.m4a")
        let good2 = makeTrack(title: "Good2")
        svc.playTracks([good1, missing, good2], startingAt: 0)
        svc.next() // lands on missing → skips to Good2
        XCTAssertEqual(svc.currentTrack?.title, "Good2")
        // Attempting to play the missing track directly also skips past it.
        svc.play(at: 1)
        XCTAssertEqual(svc.currentTrack?.title, "Good2")
    }

    @MainActor
    func testPlayNextAndAddToQueue() {
        let svc = PlaybackService()
        svc.playTracks([makeTrack(title: "A")], startingAt: 0)
        let extra = makeTrack(title: "Extra")
        svc.playNext(extra)
        XCTAssertEqual(svc.queue[1].title, "Extra")
        let tail = makeTrack(title: "Tail")
        svc.addToQueue(tail)
        XCTAssertEqual(svc.queue.last?.title, "Tail")
    }

    @MainActor
    func testShufflePreservesAllTracks() {
        let svc = PlaybackService()
        let tracks = (0 ..< 10).map { makeTrack(title: "T\($0)") }
        svc.playTracks(tracks, startingAt: 0)
        svc.toggleShuffle()
        XCTAssertTrue(svc.isShuffled)
        // Walk the whole shuffle order via manual next() (repeat off):
        // every track plays exactly once; the walk ends on the last one.
        var seen: Set<String> = [svc.currentTrack!.id]
        for _ in 0 ..< 9 {
            let before = svc.currentTrack!.id
            svc.next()
            // next() at the very end keeps the last track (no wrap).
            if svc.currentTrack!.id == before { break }
            seen.insert(svc.currentTrack!.id)
        }
        XCTAssertEqual(seen.count, 10)
    }

    @MainActor
    func testRemoveOtherTrackKeepsPlaying() {
        let svc = PlaybackService()
        svc.playTracks([makeTrack(title: "A"), makeTrack(title: "B"), makeTrack(title: "C")], startingAt: 1)
        svc.removeFromQueue(at: IndexSet(integer: 0))
        XCTAssertEqual(svc.queue.map(\.title), ["B", "C"])
        XCTAssertEqual(svc.currentTrack?.title, "B")
        XCTAssertEqual(svc.currentIndex, 0)
    }

    @MainActor
    func testRemovePlayingTrackAdvances() {
        let svc = PlaybackService()
        svc.playTracks([makeTrack(title: "A"), makeTrack(title: "B"), makeTrack(title: "C")], startingAt: 1)
        svc.removeFromQueue(at: IndexSet(integer: 1))
        XCTAssertEqual(svc.queue.map(\.title), ["A", "C"])
        // Resumes at the track that slid into the removed position.
        XCTAssertEqual(svc.currentTrack?.title, "C")
    }

    @MainActor
    func testRemovePlayingTailPlaysNewTail() {
        let svc = PlaybackService()
        svc.playTracks([makeTrack(title: "A"), makeTrack(title: "B")], startingAt: 1)
        svc.removeFromQueue(at: IndexSet(integer: 1))
        XCTAssertEqual(svc.queue.map(\.title), ["A"])
        XCTAssertEqual(svc.currentTrack?.title, "A")
    }

    @MainActor
    func testRemoveAllStops() {
        let svc = PlaybackService()
        svc.playTracks([makeTrack(title: "A")], startingAt: 0)
        svc.removeFromQueue(at: IndexSet(integer: 0))
        XCTAssertTrue(svc.queue.isEmpty)
        XCTAssertNil(svc.currentTrack)
    }

    // MARK: - Play counting (regression: finished tracks must count)

    @MainActor
    func testFinishedTrackCountsAsPlay() {
        // Directly exercise the finish path: threshold NOT reached
        // (currentTime 0), yet finishing must still record the play.
        let svc = PlaybackService()
        var recorded: [String] = []
        svc.onRecordPlay = { recorded.append($0) }
        svc.playTracks([makeTrack(title: "A")], startingAt: 0)
        XCTAssertTrue(recorded.isEmpty, "no play counted at start")
        svc.simulateFinishForTests()
        XCTAssertEqual(recorded, [svc.queue[0].id])
        // Second finish (e.g. repeat-one loop calls play(at:) which
        // re-arms; a bare duplicate finish must not double-count).
        svc.simulateFinishForTests()
        XCTAssertEqual(recorded.count, 1)
    }

    @MainActor
    func testThresholdCountsMidPlayback() {
        let svc = PlaybackService()
        var recorded: [String] = []
        svc.onRecordPlay = { recorded.append($0) }
        svc.playTracks([makeTrack(title: "A")], startingAt: 0)
        // Simulate the periodic observer crossing the threshold:
        // duration is the real fixture length (~0.5s), so any positive
        // time past 50% counts.
        svc.simulateTimeForTests(seconds: 1000)
        XCTAssertEqual(recorded.count, 1)
        svc.simulateTimeForTests(seconds: 2000)
        XCTAssertEqual(recorded.count, 1, "must fire once per track load")
    }
}
