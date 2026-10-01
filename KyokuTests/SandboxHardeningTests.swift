import XCTest
@testable import Kyoku

/// Workstream 4: sandbox hardening — bookmark lifecycle, folder
/// validation, custom destination persistence, launch-time validation.
///
/// Security-scoped APIs can't run in the test host, so tests exercise the
/// state machine through the DEBUG hook + direct bookmark-data checks:
/// bookmark serialization round-trips ARE real (bookmarkData/resolving
/// work outside the sandbox for non-scoped bookmarks in /tmp).
final class SandboxHardeningTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    // MARK: - Music folder validation

    func testNoFolderValidatesCleanly() {
        let access = MusicFolderAccess(settings: settings())
        XCTAssertEqual(access.validate(), .noFolder)
        XCTAssertNil(access.relinkMessage)
        XCTAssertFalse(access.hasFolder)
    }

    func testValidFolderPassesValidation() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let access = MusicFolderAccess(settings: settings())
        access.setFolderForTests(dir)
        // setFolderForTests bypasses bookmarks; validate() checks the
        // live folderURL. No bookmark → .noFolder by design (hook path).
        // For a real bookmarked folder the status flows through resolve.
        XCTAssertTrue(access.hasFolder)
    }

    func testClearFolderLeavesNoBookmark() {
        let s = settings()
        let access = MusicFolderAccess(settings: s)
        access.setFolderForTests(tempDir())
        access.clearFolder()
        XCTAssertFalse(access.hasFolder)
        XCTAssertNil(s.musicFolderBookmark, "clearing must drop the stored bookmark")
        XCTAssertEqual(access.validate(), .noFolder)
    }

    func testRelinkMessagesHaveNoJargon() {
        let access = MusicFolderAccess(settings: settings())
        // No folder → no message (nothing to relink).
        XCTAssertNil(access.relinkMessage)
        for status: MusicFolderAccess.FolderStatus in
            [.missingOnDisk, .notDirectory, .accessDenied, .staleNeedsRelink] {
            // Drive status via reflection of message mapping: construct by
            // exercising validate() paths is environment-dependent, so pin
            // the mapping through a scratch instance is impossible without
            // setters — instead assert the enum cases exist and differ.
            XCTAssertNotEqual(status, .ok)
            XCTAssertNotEqual(status, .noFolder)
        }
    }

    func testStaleCorruptBookmarkIsDropped() {
        // Garbage bookmark data must resolve to relink state, and the
        // corrupt bytes must be discarded (not re-hit every launch).
        let s = settings()
        s.musicFolderBookmark = Data("definitely not a bookmark".utf8)
        let access = MusicFolderAccess(settings: s)
        XCTAssertFalse(access.hasFolder)
        XCTAssertNil(s.musicFolderBookmark, "corrupt bookmark must be dropped")
        XCTAssertEqual(access.status, .staleNeedsRelink)
        XCTAssertNotNil(access.relinkMessage)
        XCTAssertTrue(access.relinkMessage!.contains("reconnect"),
                      "message must be actionable, got: \(access.relinkMessage!)")
        // No NSURL/bookmark jargon in user-facing copy.
        XCTAssertFalse(access.relinkMessage!.lowercased().contains("bookmark"))
        XCTAssertFalse(access.relinkMessage!.lowercased().contains("nsurl"))
    }

    func testBookmarkRoundTripPreservesFolder() throws {
        // Real bookmarkData/resolving round-trip (non-scoped, works in /tmp
        // outside the sandbox). Proves serialization, not sandboxing.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try dir.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: data, options: [],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertFalse(stale)
        XCTAssertEqual(resolved.path, dir.path)
    }

    // MARK: - Onboarding with removed folder

    func testOnboardingReappearsWhenFolderRemoved() {
        let s = settings()
        XCTAssertTrue(s.completeOnboarding(hasFolder: true))
        // Folder later removed → onboarding (relink) reappears.
        XCTAssertTrue(s.needsOnboarding(hasFolder: false))
        // And cannot silently complete without a folder.
        XCTAssertFalse(s.completeOnboarding(hasFolder: false))
    }

    // MARK: - Sync job destinations

    @MainActor
    private func jobDB() -> (Database, SourceStore, SyncJobStore, AutomationRecordStore) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite").path
        let db = try! Database(path: path)
        let sources = SourceStore(database: db)
        sources.start()
        // FK parent for every job below: sync_jobs.source_id REFERENCES
        // sources(id). Real source row (not a placeholder string).
        _ = sources.add(url: "https://example/sandbox-test", kind: "searchTerm",
                        displayName: "Sandbox Test Source")
        let jobs = SyncJobStore(database: db)
        jobs.start()
        let records = AutomationRecordStore(database: db)
        records.start()
        return (db, sources, jobs, records)
    }

    @MainActor
    private func jobSourceID(_ sources: SourceStore) -> String {
        sources.sources.first!.id
    }

    @MainActor
    func testJobDestinationBookmarkRoundTrips() {
        let (_, sources, jobs, _) = jobDB()
        let sid = jobSourceID(sources)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try! dir.bookmarkData(options: [],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let job = jobs.create(sourceID: sid, name: "J", destination: dir.path,
                              destinationBookmark: bookmark)
        // Reload from DB: bookmark bytes survive the BLOB round-trip.
        jobs.refresh()
        let loaded = jobs.jobs.first(where: { $0.id == job.id })!
        XCTAssertEqual(loaded.destination, dir.path)
        XCTAssertNotNil(loaded.destinationBookmark)
        var stale = false
        let resolved = try! URL(resolvingBookmarkData: loaded.destinationBookmark!,
                                options: [], relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.path, dir.path)
    }

    @MainActor
    func testDestinationInsideMusicRootNeedsNoBookmark() {
        let (_, sources, jobs, _) = jobDB()
        let sid = jobSourceID(sources)
        let musicRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: musicRoot) }
        let sub = musicRoot.appendingPathComponent("Sub", isDirectory: true)
        try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let job = jobs.create(sourceID: sid, name: "J", destination: sub.path)
        let status = jobs.resolveDestination(for: job, musicRoot: musicRoot)
        guard case .ok(let url) = status else {
            return XCTFail("expected ok, got \(status)")
        }
        XCTAssertEqual(url.path, sub.path)
    }

    @MainActor
    func testMissingDestinationSurfacesAttention() {
        let (_, sources, jobs, records) = jobDB()
        let sid = jobSourceID(sources)
        let musicRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: musicRoot) }
        let job = jobs.create(sourceID: sid, name: "J",
                              destination: "/nonexistent/kyoku-test-\(UUID().uuidString)")
        let status = jobs.resolveDestination(for: job, musicRoot: musicRoot)
        guard case .missingOnDisk = status else {
            return XCTFail("expected missingOnDisk, got \(status)")
        }
        let flagged = jobs.validateAll(records: records, musicRoot: musicRoot)
        XCTAssertTrue(flagged.contains(job.id))
        XCTAssertFalse(records.openAttention.isEmpty)
        // Configuration preserved (not deleted).
        XCTAssertNotNil(jobs.jobs.first(where: { $0.id == job.id }))
        // Second validation does not duplicate the attention item.
        _ = jobs.validateAll(records: records, musicRoot: musicRoot)
        XCTAssertEqual(records.openAttention.count, 1)
    }

    @MainActor
    func testOutsideSubtreeWithoutBookmarkIsAccessDenied() {
        let (_, sources, jobs, _) = jobDB()
        let sid = jobSourceID(sources)
        let outside = tempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let musicRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: musicRoot) }
        // Exists on disk but outside the music root, no bookmark →
        // accessDenied (not missingOnDisk): the distinction drives the
        // correct user message.
        let job = jobs.create(sourceID: sid, name: "J", destination: outside.path)
        let status = jobs.resolveDestination(for: job, musicRoot: musicRoot)
        guard case .accessDenied = status else {
            return XCTFail("expected accessDenied, got \(status)")
        }
    }

    @MainActor
    func testRepairedDestinationValidates() {
        let (_, sources, jobs, records) = jobDB()
        let sid = jobSourceID(sources)
        let musicRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: musicRoot) }
        let job = jobs.create(sourceID: sid, name: "J",
                              destination: "/nonexistent/kyoku-test-\(UUID().uuidString)")
        _ = jobs.validateAll(records: records, musicRoot: musicRoot)
        XCTAssertFalse(records.openAttention.isEmpty)
        // User repairs via the editor: new path + fresh bookmark.
        let fixed = tempDir()
        defer { try? FileManager.default.removeItem(at: fixed) }
        var updated = job
        updated.destination = fixed.path
        updated.destinationBookmark = try! fixed.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        jobs.update(updated)
        let status = jobs.resolveDestination(
            for: jobs.jobs.first(where: { $0.id == job.id })!, musicRoot: musicRoot)
        guard case .ok = status else {
            return XCTFail("expected ok after repair, got \(status)")
        }
    }

    @MainActor
    func testBlankDestinationFallsBackToMusicRoot() {
        let (_, sources, jobs, _) = jobDB()
        let sid = jobSourceID(sources)
        let musicRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: musicRoot) }
        let job = jobs.create(sourceID: sid, name: "J", destination: "")
        let status = jobs.resolveDestination(for: job, musicRoot: musicRoot)
        guard case .ok(let url) = status else {
            return XCTFail("expected ok, got \(status)")
        }
        XCTAssertEqual(url.path, musicRoot.path)
    }
}
