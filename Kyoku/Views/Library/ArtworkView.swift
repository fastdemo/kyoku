import AVFoundation
import SwiftUI

/// Artwork with graceful fallback: cached file → embedded → remote → placeholder.
///
/// Loading discipline:
/// - Local sources (cache file, embedded tags) resolve synchronously —
///   cheap, no scroll hitch.
/// - Remote covers load ASYNC on first sight (never `Data(contentsOf:)`
///   on the main thread), then publish and memory-cache. Duplicate
///   in-flight requests for the same URL coalesce.
/// - Missing artwork fails gracefully to the placeholder; no disk cache
///   yet (memory NSCache only, 500 images).
struct ArtworkView: View {
    var artworkPath: String?
    var coverURL: String?
    var localPath: String?
    var size: CGFloat = 48

    @State private var remoteImage: NSImage?

    var body: some View {
        Group {
            if let image = ArtworkCache.shared.localImage(
                artworkPath: artworkPath, localPath: localPath) ?? remoteImage {
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
        .task(id: coverURL) {
            // Async remote fetch only when local sources missed.
            guard ArtworkCache.shared.localImage(
                artworkPath: artworkPath, localPath: localPath) == nil,
                  let coverURL, !coverURL.isEmpty
            else { return }
            if let img = await ArtworkCache.shared.remoteImage(urlString: coverURL) {
                remoteImage = img
            }
        }
    }
}

final class ArtworkCache: Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    /// In-flight remote fetches, coalesced by URL.
    private let inflight = InflightBox()
    private let fm = FileManager.default

    private init() {
        cache.countLimit = 500
    }

    /// Synchronous local resolution: cache file → embedded tags → memory
    /// hit. Never touches the network. Nil = show placeholder / try remote.
    func localImage(artworkPath: String?, localPath: String?) -> NSImage? {
        if let artworkPath {
            let key = "file:\(artworkPath)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            if let img = NSImage(contentsOfFile: artworkPath) {
                cache.setObject(img, forKey: key)
                return img
            }
        }
        if let localPath {
            let key = "embedded:\(localPath)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            if let img = embeddedArtwork(localPath: localPath) {
                cache.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }

    /// Async remote cover fetch with in-flight coalescing + memory cache.
    /// Bounded at 2MB; failures return nil (caller keeps placeholder).
    func remoteImage(urlString: String) async -> NSImage? {
        let key = "remote:\(urlString)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        return await inflight.run(key: urlString) { [cache] in
            // Recheck after acquiring the gate (another task may have won).
            if let hit = cache.object(forKey: key) { return hit }
            guard let url = URL(string: urlString) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard data.count < 2_000_000,
                      let img = NSImage(data: data)
                else { return nil }
                cache.setObject(img, forKey: key)
                return img
            } catch {
                return nil
            }
        }
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

/// Coalesces concurrent fetches for the same key: the first task runs the
/// operation, joiners await its result instead of refetching.
private final class InflightBox: Sendable {
    private var tasks: [String: Task<NSImage?, Never>] = [:]
    private let lock = NSLock()

    func run(key: String, operation: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
        let task: Task<NSImage?, Never> = lock.withLock {
            if let existing = tasks[key] { return existing }
            let created = Task { await operation() }
            tasks[key] = created
            return created
        }
        let result = await task.value
        lock.withLock { tasks.removeValue(forKey: key) }
        return result
    }
}
