import Foundation

/// Reusable download configuration. Phase 0: friendly defaults only.
/// Advanced spotDL/yt-dlp/FFmpeg options arrive in Phase 5; the struct
/// is Codable so profiles can persist in the database then.
struct DownloadProfile: Identifiable, Hashable, Sendable, Codable {
    enum AudioFormat: String, Sendable, Codable, CaseIterable {
        case m4a, mp3, flac, opus
    }

    let id: String
    var name: String
    var format: AudioFormat
    var embedArtwork: Bool
    var embedLyrics: Bool
    var embedMetadata: Bool

    static let appleLibrary = DownloadProfile(
        id: "apple-library",
        name: "Apple Library",
        format: .m4a,
        embedArtwork: true,
        embedLyrics: true,
        embedMetadata: true
    )

    static let lossless = DownloadProfile(
        id: "lossless",
        name: "Lossless",
        format: .flac,
        embedArtwork: true,
        embedLyrics: true,
        embedMetadata: true
    )

    static let portable = DownloadProfile(
        id: "portable",
        name: "Portable",
        format: .mp3,
        embedArtwork: true,
        embedLyrics: false,
        embedMetadata: true
    )

    static var builtins: [DownloadProfile] {
        [.appleLibrary, .lossless, .portable]
    }
}
