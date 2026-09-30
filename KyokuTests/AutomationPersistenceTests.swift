import XCTest
@testable import Kyoku

/// Automation persistence: sources, jobs, snapshots, runs, attention,
/// activity — all through the REAL Database (temp file per test).
/// Also covers the v3→v4 migration preserving Phase 2 library data.
final class AutomationPersistenceTests: XCTestCase {
    var dbPath: String!
    var db: Database!

    @MainActor override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        db = try! Database(path: dbPath)
    }

    @MainActor override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    @MainActor func testSourceCRUD() {
        let store = SourceStore(database: db)
        store.start()
        let s = store.add(url: "https://open.spotify.com/playlist/x",
                          kind: "spotifyPlaylist", displayName: "Mix")
        XCTAssertEqual(store.sources.count, 1)
        store.setEnabled(id: s.id, enabled: false)
        XCTAssertFalse(store.sources.first!.enabled)
        store.recordCheck(id: s.id, success: true)
        XCTAssertNotNil(store.sources.first!.lastSuccessAt)
        // Reopen persists.
        let store2 = SourceStore(database: db)
        store2.start()
        XCTAssertEqual(store2.sources.first?.displayName, "Mix")
    }

    @MainActor func testSnapshotRoundTrip() {
        let store = SourceStore(database: db)
        store.start()
        let s = store.add(url: "https://example/x", kind: "searchTerm", displayName: "X")
        XCTAssertTrue(store.loadSnapshot(sourceID: s.id).isEmpty)
        let entries = [SnapshotEntry(key: "url:a", url: "a", title: "T", artist: "A",
                                      album: "Al", duration: 1, position: 0)]
        store.saveSnapshot(sourceID: s.id, entries: entries)
        XCTAssertEqual(store.loadSnapshot(sourceID: s.id), entries)
    }

    @MainActor func testJobCRUDAndOutcome() {
        let sources = SourceStore(database: db)
        sources.start()
        let s = sources.add(url: "https://example/x", kind: "searchTerm", displayName: "X")
        let jobs = SyncJobStore(database: db)
        jobs.start()
        let j = jobs.create(sourceID: s.id, name: "Job", destination: "/tmp/x",
                            schedule: .hourly, removalPolicy: .delete)
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertEqual(jobs.jobs.first?.schedule, .hourly)
        jobs.recordRunOutcome(id: j.id, success: false, error: "boom")
        XCTAssertEqual(jobs.jobs.first?.consecutiveFailures, 1)
        jobs.recordRunOutcome(id: j.id, success: true)
        XCTAssertEqual(jobs.jobs.first?.consecutiveFailures, 0)
        XCTAssertNotNil(jobs.jobs.first?.lastSuccessAt)
    }

    @MainActor func testRunLifecycleAndAttentionAndActivity() {
        let sources = SourceStore(database: db)
        sources.start()
        let src = sources.add(url: "https://example/x", kind: "searchTerm", displayName: "X")
        let jobs = SyncJobStore(database: db)
        jobs.start()
        let job = jobs.create(sourceID: src.id, name: "J", destination: "/tmp/x")
        let records = AutomationRecordStore(database: db)
        records.start()
        var run = records.beginRun(syncJobID: job.id)
        run.status = .succeeded
        run.addedCount = 2
        run.finishedAt = Date()
        records.finishRun(run)
        XCTAssertEqual(records.runs.count, 1)
        XCTAssertEqual(records.runs.first?.addedCount, 2)

        let item = records.addAttention(AttentionItem(
            kind: "downloadFailed", title: "Failed: X", trackURL: "https://t/x"))
        XCTAssertEqual(records.openAttention.count, 1)
        XCTAssertNotNil(records.openItemForTrack(kind: "downloadFailed", trackURL: "https://t/x"))
        records.resolveAttention(id: item.id)
        XCTAssertTrue(records.openAttention.isEmpty)

        records.logActivity(syncJobID: job.id, kind: "succeeded", title: "Done")
        XCTAssertEqual(records.recentActivity.count, 1)
    }

    @MainActor func testInterruptedRunsListed() {
        let sources = SourceStore(database: db)
        sources.start()
        let src = sources.add(url: "https://example/y", kind: "searchTerm", displayName: "Y")
        let jobs = SyncJobStore(database: db)
        jobs.start()
        let job = jobs.create(sourceID: src.id, name: "J", destination: "/tmp/x")
        let records = AutomationRecordStore(database: db)
        records.start()
        _ = records.beginRun(syncJobID: job.id)
        XCTAssertEqual(records.interruptedRuns().count, 1)
    }

    @MainActor func testV3LibrarySurvivesV4Migration() throws {
        // Build a v3-shaped DB in a scratch file via the CURRENT code
        // (which is v4): downgrade it to v3 by dropping v4 objects, add
        // library rows, then reopen (migrates back to v4) and verify.
        // Simpler + stronger: use the real Phase 2 shape backup.
        let backup = "/tmp/kyoku_phase2_shape.sqlite"
        guard FileManager.default.fileExists(atPath: backup) else {
            throw XCTSkip("Phase 2 shape backup not present in this environment")
        }
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        try FileManager.default.copyItem(atPath: backup, toPath: probe)
        defer { try? FileManager.default.removeItem(atPath: probe) }
        let migrated = try Database(path: probe)
        let version = try migrated.query("PRAGMA user_version;").first?.values.first?.integer
        XCTAssertEqual(version, Database.schemaVersion)
        let tracks = try migrated.query("SELECT COUNT(*) AS c FROM tracks;")
        XCTAssertEqual(tracks.first?["c"]?.integer, 1, "Phase 2 track must survive")
        let tables = try migrated.query("SELECT name FROM sqlite_master WHERE type='table';")
            .compactMap { $0["name"]?.text }
        for expected in ["sources", "sync_jobs", "source_snapshots", "sync_runs",
                         "attention_items", "activity_events"] {
            XCTAssertTrue(tables.contains(expected), "missing \(expected)")
        }
        // Library still loads through the new code.
        let store = LibraryStore(database: migrated)
        XCTAssertEqual(store.tracks.count, 1)
    }
}
