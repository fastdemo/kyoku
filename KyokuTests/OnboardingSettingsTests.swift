import XCTest
@testable import Kyoku

/// Workstream 3: onboarding state machine, settings persistence, and the
/// shared folder picker contract. No interactive NSOpenPanel in tests —
/// folder validity is injected via hasFolder (same seam production uses).
final class OnboardingSettingsTests: XCTestCase {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    // MARK: - Onboarding transitions

    func testFreshStateNeedsOnboarding() {
        XCTAssertTrue(settings().needsOnboarding(hasFolder: false))
        XCTAssertTrue(settings().needsOnboarding(hasFolder: true),
                      "flag defaults false → onboarding regardless of folder")
    }

    func testCompletionRequiresFolder() {
        let s = settings()
        XCTAssertFalse(s.completeOnboarding(hasFolder: false))
        XCTAssertFalse(s.hasCompletedOnboarding,
                       "invalid folder must not silently complete setup")
        XCTAssertTrue(s.needsOnboarding(hasFolder: false))
    }

    func testSuccessfulCompletionPersists() {
        let s = settings()
        XCTAssertTrue(s.completeOnboarding(hasFolder: true))
        XCTAssertTrue(s.hasCompletedOnboarding)
        XCTAssertFalse(s.needsOnboarding(hasFolder: true))
    }

    func testStaleFlagWithoutFolderRepresentsOnboarding() {
        // Simulates a lost bookmark after a completed setup: flag is set
        // but no usable folder exists → onboarding reappears (relink).
        let s = settings()
        XCTAssertTrue(s.completeOnboarding(hasFolder: true))
        XCTAssertTrue(s.needsOnboarding(hasFolder: false))
        XCTAssertFalse(s.needsOnboarding(hasFolder: true))
    }

    func testIncompleteStateRemainsIncomplete() {
        let s = settings()
        XCTAssertTrue(s.needsOnboarding(hasFolder: true))
        // No completion call → still needs onboarding.
        XCTAssertTrue(s.needsOnboarding(hasFolder: true))
        XCTAssertFalse(s.hasCompletedOnboarding)
    }

    // MARK: - Default download profile

    func testDefaultProfileIsAppleLibrary() {
        XCTAssertEqual(settings().defaultProfileID, DownloadProfile.appleLibrary.id)
        XCTAssertEqual(settings().defaultProfile.id, DownloadProfile.appleLibrary.id)
    }

    func testChangingDefaultProfilePersists() {
        let s = settings()
        s.defaultProfileID = DownloadProfile.lossless.id
        XCTAssertEqual(s.defaultProfile.id, DownloadProfile.lossless.id)
        // Unknown IDs fall back safely (corrupt prefs can never break it).
        s.defaultProfileID = "no-such-profile"
        XCTAssertEqual(s.defaultProfile.id, DownloadProfile.appleLibrary.id)
    }

    func testProfileValidationOnLoad() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set("bogus", forKey: "defaultProfileID")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.defaultProfileID, DownloadProfile.appleLibrary.id)
    }

    // MARK: - Notifications setting

    func testNotificationToggleAffectsNotifier() {
        let original = SyncNotifier.enabled
        defer { SyncNotifier.enabled = original }
        SyncNotifier.enabled = false
        XCTAssertFalse(SyncNotifier.enabled)
        SyncNotifier.enabled = true
        XCTAssertTrue(SyncNotifier.enabled)
    }

    // MARK: - FolderPicker contract (non-interactive)

    func testFolderAccessRoundTripWithoutPanel() {
        // The shared picker delegates persistence to MusicFolderAccess;
        // in the test host (no security-scoped bookmarks) the DEBUG hook
        // provides the same folderURL contract production reads.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let access = MusicFolderAccess(settings: settings())
        access.setFolderForTests(dir)
        XCTAssertTrue(access.hasFolder)
        XCTAssertEqual(access.folderURL?.path, dir.path)
        access.clearFolder()
        XCTAssertFalse(access.hasFolder)
    }
}
