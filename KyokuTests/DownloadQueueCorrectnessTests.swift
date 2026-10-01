import XCTest
@testable import Kyoku

/// Workstream 1: download queue correctness — retry/backoff state,
/// clearFinished tombstones, UNIQUE(source_url), cancel semantics.
///
/// These tests use a fake engine (no subprocesses). Real cancel-kill and
/// real E2E download are verified separately (acceptance checklist).
final class DownloadQueueCorrectnessTests: XCTestCase {
    // MARK: - Fake engine

    /// Controllable DownloadEngine: downloads complete instantly unless
    /// told to fail or hang. Tracks registrations for cancel verification.
    actor FakeEngine: DownloadEngine {
        var registrationHint: String?
        var cancelledIDs: [String] = []
        var terminatedRegistrations: [String] = []
        /// URLs that fail with a retryable error, N times before succeeding.
        var failCounts: [String: Int] = [:]
        /// URLs that fail permanently.
        var permanentFailures: Set<String> = []
        /// If true, downloadTrack never finishes (for cancel tests).
        var hangURLs: Set<String> = []
        /// Registration observed at download time, by song URL.
        var seenRegistrations: [String: String] = [:]
        /// Profile ID observed at download time, by song URL.
        var seenProfiles: [String: String] = [:]

        func setRegistrationHint(_ id: String?) async { registrationHint = id }
        func classifySource(_ input: String) -> SourceKind { .searchTerm }
        func resolveSource(_ url: String) async throws -> [DiscoveredTrack] { [] }

        func downloadTrack(_ song: ResolvedSong, profile: DownloadProfile,
                           destination: URL) async throws -> AsyncThrowingStream<DownloadProgress, Error> {
            seenRegistrations[song.url] = registrationHint
            registrationHint = nil
            seenProfiles[song.url] = profile.id
            if hangURLs.contains(song.url) {
                // Hang until the harness task is cancelled.
                return AsyncThrowingStream { continuation in
                    // Never finishes; the queue's cancel path kills the
                    // consumer via engine.cancel + state flag.
                    _ = continuation
                }
            }
            if permanentFailures.contains(song.url) {
                throw DownloadEngineError.invalidInput("bad input")
            }
            if let remaining = failCounts[song.url], remaining > 0 {
                failCounts[song.url] = remaining - 1
                throw DownloadEngineError.timedOut(operation: "Test")
            }
            let url = destination.appendingPathComponent("done-\(song.songID).mp3")
            try? "x".write(to: url, atomically: true, encoding: .utf8)
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(url))
                continuation.finish()
            }
        }

        func cancel(taskID: String) async {
            cancelledIDs.append(taskID)
            terminatedRegistrations.append(taskID)
        }
    }

    // MARK: - Harness

    var dbPath: String!
    var db: Database!
    var musicDir: URL!
    var folderAccess: MusicFolderAccess!

    @MainActor
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        db = try! Database(path: dbPath)
        musicDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        folderAccess = MusicFolderAccess(settings: settings)
        folderAccess.setFolderForTests(musicDir)
    }

    @MainActor
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(at: musicDir)
        super.tearDown()
    }

    @MainActor
    private func makeQueue(engine: FakeEngine) -> DownloadQueue {
        let library = LibraryStore(database: db)
        let q = DownloadQueue(database: db, engine: engine, library: library,
                              musicFolderAccess: folderAccess)
        q.start()
        return q
    }

    /// Simulate an app restart for queue `q`: stop its worker loop so no
    /// two loops drive the same DB, then build a fresh queue over the
    /// same database (fresh in-memory state, persisted rows only).
    @MainActor
    private func restartQueue(_ q: DownloadQueue, engine: FakeEngine) -> DownloadQueue {
        q.stopForTests()
        let library = LibraryStore(database: db)
        let q2 = DownloadQueue(database: db, engine: engine, library: library,
                               musicFolderAccess: folderAccess)
        q2.start()
        return q2
    }

    private func song(url: String, id: String) -> ResolvedSong {
        ResolvedSong(name: "T\(id)", artist: "A", artists: ["A"], albumName: "Al",
                     albumArtist: "A", duration: 200, year: nil, date: nil,
                     trackNumber: 1, discNumber: 1, songID: id, url: url,
                     downloadURL: nil, coverURL: nil, isrc: nil, explicit: false,
                     lyrics: nil, listName: nil, listPosition: nil)
    }

    /// Wait until condition holds or timeout (polls, main-actor friendly).
    /// Uses Task.sleep (not RunLoop spin) so other MainActor tasks —
    /// including the queue worker — can make progress while waiting.
    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 15,
                           _ check: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            if Date() > deadline {
                XCTFail("timeout: \(message)")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Test-only: force a task's retry deadline to now (fast-forwards
    /// backoff without waiting minutes). Implemented via retry() when
    /// parked, or via direct DB update + reload for pending tasks.
    @MainActor
    private func forceRetryableNow(_ q: DownloadQueue, taskID: String) {
        // Pending-with-deadline tasks: clear the deadline in the DB and
        // ask the queue to reload that task's scheduling fields.
        q.clearRetryDeadlineForTests(taskID: taskID)
    }

    // MARK: - Tests

    @MainActor
    func testRetryableFailureBacksOffThenSucceeds() async {
        let engine = FakeEngine()
        await engine.setFailCounts(["https://t/1": 1])
        let q = makeQueue(engine: engine)
        q.enqueue([song(url: "https://t/1", id: "1")], sourceURL: "test")
        // First attempt fails → pending with backoff, attempts=1.
        await waitUntil("requeue after failure") {
            q.tasks.first?.state == .pending && (q.tasks.first?.attempts ?? 0) >= 1
        }
        let task = q.tasks.first!
        XCTAssertEqual(task.attempts, 1)
        XCTAssertNotNil(task.nextRetryAt)
        XCTAssertTrue(task.nextRetryAt! > Date())
        // Fast-forward: clear the deadline, worker picks it up, succeeds.
        forceRetryableNow(q, taskID: task.id)
        await waitUntil("success after retry") { q.tasks.first?.state == .done }
        XCTAssertEqual(q.tasks.first?.attempts, 2)
    }

    @MainActor
    func testPermanentFailureParksImmediately() async {
        let engine = FakeEngine()
        let q = makeQueue(engine: engine)
        Task { await engine.addPermanentFailure("https://t/perm") }
        q.enqueue([song(url: "https://t/perm", id: "p")], sourceURL: "test")
        await waitUntil("parked failed") { q.tasks.first?.state == .failed }
        XCTAssertEqual(q.tasks.first?.attempts, 1)
        XCTAssertNil(q.tasks.first?.nextRetryAt)
    }

    @MainActor
    func testMaxAttemptsParks() async {
        let engine = FakeEngine()
        await engine.setFailCounts(["https://t/flaky": 99])
        let q = makeQueue(engine: engine)
        q.enqueue([song(url: "https://t/flaky", id: "f")], sourceURL: "test")
        // Each failure requeues with backoff; fast-forward deadlines.
        for _ in 0 ..< DownloadTask.maxAttempts + 2 {
            await waitUntil("settle") {
                let s = q.tasks.first?.state
                return s == .failed || (s == .pending && (q.tasks.first?.nextRetryAt != nil))
            }
            if q.tasks.first?.state == .failed { break }
            forceRetryableNow(q, taskID: q.tasks.first!.id)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(q.tasks.first?.state, .failed)
        XCTAssertEqual(q.tasks.first?.attempts, DownloadTask.maxAttempts)
    }

    @MainActor
    func testManualRetryResetsBackoff() async {
        let engine = FakeEngine()
        let q = makeQueue(engine: engine)
        Task { await engine.addPermanentFailure("https://t/m") }
        q.enqueue([song(url: "https://t/m", id: "m")], sourceURL: "test")
        await waitUntil("parked") { q.tasks.first?.state == .failed }
        q.retry(taskID: q.tasks.first!.id)
        let task = q.tasks.first!
        XCTAssertEqual(task.state, .pending)
        XCTAssertEqual(task.attempts, 0)
        XCTAssertNil(task.nextRetryAt)
        XCTAssertNil(task.lastError)
    }

    @MainActor
    func testClearFinishedStaysClearedAfterReload() async {
        let engine = FakeEngine()
        let q = makeQueue(engine: engine)
        q.enqueue([song(url: "https://t/c", id: "c")], sourceURL: "test")
        await waitUntil("done") { q.tasks.first?.state == .done }
        q.clearFinished()
        XCTAssertTrue(q.tasks.isEmpty)
        // Simulate restart: new queue over the same DB.
        let q2 = restartQueue(q, engine: engine)
        XCTAssertTrue(q2.tasks.isEmpty, "cleared tasks must not resurrect")
        _ = q2
    }

    @MainActor
    func testDuplicateEnqueueRefreshesInsteadOfDuplicating() async {
        let engine = FakeEngine()
        let q = makeQueue(engine: engine)
        q.enqueue([song(url: "https://t/d", id: "d")], sourceURL: "test")
        await waitUntil("done") { q.tasks.first?.state == .done }
        q.enqueue([song(url: "https://t/d", id: "d")], sourceURL: "test")
        XCTAssertEqual(q.tasks.count, 1, "same URL must not create a second task")
    }

    @MainActor
    func testCancelActiveTaskKillsEngine() async {
        let engine = FakeEngine()
        await engine.addHang("https://t/hang")
        let q = makeQueue(engine: engine)
        q.enqueue([song(url: "https://t/hang", id: "h")], sourceURL: "test")
        await waitUntil("active") { q.activeTaskID != nil }
        let activeID = q.activeTaskID!
        q.cancel(taskID: activeID)
        await waitUntil("cancelled") { q.tasks.first?.state == .cancelled }
        let cancelled = await engine.cancelledIDs
        XCTAssertTrue(cancelled.contains(activeID), "engine.cancel must receive the task ID")
        let seen = await engine.seenRegistrations
        XCTAssertEqual(seen["https://t/hang"], activeID,
                       "subprocess registration must equal the queue task ID")
    }

    @MainActor
    func testRetryStateSurvivesRestart() async {
        let engine = FakeEngine()
        let q = makeQueue(engine: engine)
        Task { await engine.setFailCounts(["https://t/r": 99]) }
        q.enqueue([song(url: "https://t/r", id: "r")], sourceURL: "test")
        await waitUntil("backoff") {
            q.tasks.first?.state == .pending && (q.tasks.first?.attempts ?? 0) >= 1
        }
        let attempts = q.tasks.first!.attempts
        let deadline = q.tasks.first!.nextRetryAt
        XCTAssertNotNil(deadline)
        // Restart: new queue over same DB preserves attempts + deadline.
        let q2 = restartQueue(q, engine: engine)
        XCTAssertEqual(q2.tasks.first?.attempts, attempts)
        XCTAssertEqual(q2.tasks.first?.nextRetryAt?.timeIntervalSince1970,
                       deadline?.timeIntervalSince1970)
    }

    @MainActor
    func testBackoffSchedule() {
        XCTAssertEqual(DownloadTask.backoffDelay(attempt: 0), 60)
        XCTAssertEqual(DownloadTask.backoffDelay(attempt: 1), 120)
        XCTAssertEqual(DownloadTask.backoffDelay(attempt: 2), 240)
        XCTAssertEqual(DownloadTask.backoffDelay(attempt: 10), 3600)
        XCTAssertEqual(DownloadTask.maxAttempts, 5)
    }

    @MainActor
    func testErrorRetryability() {
        XCTAssertTrue(DownloadEngineError.timedOut(operation: "x").isRetryable)
        XCTAssertTrue(DownloadEngineError.backendFailed(exitCode: 1, message: "x").isRetryable)
        XCTAssertFalse(DownloadEngineError.backendMissing.isRetryable)
        XCTAssertFalse(DownloadEngineError.invalidInput("x").isRetryable)
        XCTAssertFalse(DownloadEngineError.parseFailed("x").isRetryable)
    }

    @MainActor
    func testSyncJobProfileReachesDownload() async {
        // A task enqueued with a job's profileID must download with THAT
        // profile, not the global default — even when the default changes
        // afterwards. Regression test for the Workstream 3 one-line fix.
        // profileForJob mirrors production: resolve the task's profileID
        // against builtins, fall back to the default when unknown.
        let engine = FakeEngine()
        let library = LibraryStore(database: db)
        let q = DownloadQueue(database: db, engine: engine, library: library,
                              musicFolderAccess: folderAccess,
                              defaultProfile: { .portable },
                              profileForJob: { id in
                                  DownloadProfile.builtins.first { $0.id == id }
                              })
        q.start()
        q.enqueue([song(url: "https://t/prof", id: "prof")], sourceURL: "test",
                  profileID: DownloadProfile.lossless.id)
        await waitUntil("done") { q.tasks.first?.state == .done }
        let seen = await engine.seenProfiles
        XCTAssertEqual(seen["https://t/prof"], DownloadProfile.lossless.id,
                       "job profile must reach the backend, not the global default")
    }

    @MainActor
    func testOneOffUsesDefaultProfile() async {
        let engine = FakeEngine()
        let library = LibraryStore(database: db)
        let q = DownloadQueue(database: db, engine: engine, library: library,
                              musicFolderAccess: folderAccess,
                              defaultProfile: { .portable },
                              profileForJob: { _ in nil })
        q.start()
        q.enqueue([song(url: "https://t/oneoff", id: "o")], sourceURL: "test")
        await waitUntil("done") { q.tasks.first?.state == .done }
        let seen = await engine.seenProfiles
        XCTAssertEqual(seen["https://t/oneoff"], DownloadProfile.portable.id,
                       "one-off tasks without profileID use the configured default")
    }

    @MainActor
    func testChangingDefaultDoesNotMutateEnqueuedTasks() async {
        // Enqueue under one default, change the default mid-flight, verify
        // the task keeps its original profile (persisted at enqueue).
        var currentDefault = DownloadProfile.appleLibrary
        let engine = FakeEngine()
        let library = LibraryStore(database: db)
        let q = DownloadQueue(database: db, engine: engine, library: library,
                              musicFolderAccess: folderAccess,
                              defaultProfile: { currentDefault },
                              profileForJob: { _ in nil })
        q.start()
        // Hang the first task so we can change the default mid-flight.
        await engine.addHang("https://t/pinned")
        q.enqueue([song(url: "https://t/pinned", id: "pin")], sourceURL: "test",
                  profileID: DownloadProfile.lossless.id)
        await waitUntil("active") { q.activeTaskID != nil }
        currentDefault = .portable
        q.cancel(taskID: q.activeTaskID!)
        await waitUntil("cancelled") { q.tasks.first?.state == .cancelled }
        // The task's persisted profileID is unchanged by the default flip.
        XCTAssertEqual(q.tasks.first?.profileID, DownloadProfile.lossless.id)
    }
}

// MARK: - FakeEngine test helpers (isolated to avoid actor reentrancy in tests)

extension DownloadQueueCorrectnessTests.FakeEngine {
    func setFailCounts(_ counts: [String: Int]) { failCounts = counts }
    func addPermanentFailure(_ url: String) { permanentFailures.insert(url) }
    func addHang(_ url: String) { hangURLs.insert(url) }
}
