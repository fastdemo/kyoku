import Combine
import Foundation

/// Persistent user settings. Backed by UserDefaults (sandbox-safe).
/// Database holds library data; this holds preferences only.
final class AppSettings: ObservableObject {
    @Published var musicFolderBookmark: Data? {
        didSet { defaults.set(musicFolderBookmark, forKey: Keys.musicFolderBookmark) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let musicFolderBookmark = "musicFolderBookmark"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let defaultProfileID = "defaultProfileID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.musicFolderBookmark = defaults.data(forKey: Keys.musicFolderBookmark)
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.defaultProfileID = Self.validatedProfileID(defaults.string(forKey: Keys.defaultProfileID))
    }

    // MARK: - Default download profile

    /// Profile used for one-off downloads (DownloadQueue) where no sync job
    /// dictates the profile. Persisted; changing it never mutates existing
    /// jobs (they carry their own profileID).
    @Published var defaultProfileID: String {
        didSet { defaults.set(defaultProfileID, forKey: Keys.defaultProfileID) }
    }

    var defaultProfile: DownloadProfile {
        DownloadProfile.builtins.first { $0.id == defaultProfileID } ?? .appleLibrary
    }

    private static func validatedProfileID(_ raw: String?) -> String {
        guard let raw,
              DownloadProfile.builtins.contains(where: { $0.id == raw })
        else { return DownloadProfile.appleLibrary.id }
        return raw
    }

    // MARK: - Onboarding state machine

    /// Onboarding is complete only when the flag is set AND a usable music
    /// folder exists. A stale flag with no folder (e.g. bookmark lost)
    /// re-presents onboarding rather than stranding the user in an empty app.
    /// `hasFolder` is injected so tests don't need security-scoped bookmarks.
    func needsOnboarding(hasFolder: Bool) -> Bool {
        !hasCompletedOnboarding || !hasFolder
    }

    /// Mark complete. Callers must verify `hasFolder` first — this setter
    /// refuses to persist completion without one (invalid folder cannot
    /// silently complete setup).
    /// - Returns: true if completion was recorded.
    @discardableResult
    func completeOnboarding(hasFolder: Bool) -> Bool {
        guard hasFolder else { return false }
        hasCompletedOnboarding = true
        return true
    }
}
