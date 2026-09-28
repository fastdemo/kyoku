import AVFoundation
import Foundation

/// File-tag enrichment for ingestion. Reads what spotDL actually wrote
/// into the audio file (duration, embedded artwork) so the library can
/// verify provider metadata and display real artwork.
///
/// Precedence rule (field by field, see LibraryStore.importFile):
/// ResolvedSong wins for all text metadata. File tags fill ONLY:
/// - duration, when the provider reports 0/missing;
/// - artwork, when no cached artwork exists yet.
/// A missing or inferior file tag never overwrites valid provider data.
struct FileMetadataReader {
    struct FileTags: Sendable {
        var duration: Int = 0
        var hasArtwork: Bool = false
    }

    /// Read duration + artwork presence without decoding audio.
    /// Returns empty tags (never throws) when the file is missing,
    /// unsupported, or unreadable — ingestion must not fail on tags.
    static func read(url: URL) -> FileTags {
        var tags = FileTags()
        let asset = AVURLAsset(url: url)
        // Duration: prefer the asset's own timing (what will actually play).
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 {
            tags.duration = Int(seconds.rounded())
        }
        // Artwork presence: common artwork key, loaded synchronously is
        // fine here — metadata is already parsed with the asset header.
        let artwork = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            withKey: AVMetadataKey.commonKeyArtwork,
            keySpace: AVMetadataKeySpace.common
        )
        tags.hasArtwork = !artwork.isEmpty
        return tags
    }
}
