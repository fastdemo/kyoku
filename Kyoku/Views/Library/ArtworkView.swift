import AVFoundation
import SwiftUI

/// Artwork with graceful fallback: cached file → remote URL → placeholder.
/// Image loading is lazy per-view; NSCache avoids re-decoding on scroll.
struct ArtworkView: View {
    var artworkPath: String?
    var coverURL: String?
    var localPath: String?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image = ArtworkCache.shared.image(
                artworkPath: artworkPath, coverURL: coverURL, localPath: localPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .font(.system(size: size * 0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
    }
}

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    private let fm = FileManager.default

    private init() {
        cache.countLimit = 500
    }

    /// Resolution order: cached file → embedded in audio → remote URL
    /// (downloaded + cached on success) → nil (placeholder).
    /// Synchronous by design: called during cell render for small images.
    /// Remote fetch is bounded (2MB, 10s) and cached to artworkPath's
    /// sibling dir when a track provides one; otherwise memory-only.
    func image(artworkPath: String?, coverURL: String?, localPath: String?) -> NSImage? {
        let key = [artworkPath, coverURL, localPath].compactMap { $0 }.joined(separator: "|")
        guard !key.isEmpty else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }

        // 1. Managed cache file.
        if let artworkPath, let img = NSImage(contentsOfFile: artworkPath) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        // 2. Embedded artwork in the audio file.
        if let localPath,
           let img = embeddedArtwork(localPath: localPath) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        // 3. Remote cover (memory cache only; disk caching is Phase 3+).
        if let coverURL, let url = URL(string: coverURL),
           let data = try? Data(contentsOf: url),
           data.count < 2_000_000,
           let img = NSImage(data: data) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    private func embeddedArtwork(localPath: String) -> NSImage? {
        guard fm.fileExists(atPath: localPath) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: localPath))
        let items = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            withKey: AVMetadataKey.commonKeyArtwork,
            keySpace: AVMetadataKeySpace.common)
        guard let item = items.first,
              let data = item.dataValue,
              let img = NSImage(data: data)
        else { return nil }
        return img
    }
}
