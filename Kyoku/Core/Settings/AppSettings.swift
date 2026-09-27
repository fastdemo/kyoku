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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.musicFolderBookmark = defaults.data(forKey: Keys.musicFolderBookmark)
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }
}
