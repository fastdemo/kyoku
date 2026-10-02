import AppKit
import Foundation

/// Remote playlist artwork fetcher + managed cache. Parallel to
/// ArtworkStore (track-embedded art): downloads the playlist's remote
/// cover ONCE at import, stores it under
/// `<Application Support>/Kyoku/Artwork/playlist-<id>.jpg`, and returns
/// the local path for the playlists row. Later renders never touch the
/// network for this playlist. Failures return nil (placeholder shows).
enum PlaylistArtwork {
    /// Fetch + cache. Bounded at 2 MB; JPEG-normalized at 1024px via the
    /// same pipeline as track art. Never throws.
    static func fetch(urlString: String, playlistID: String) async -> String? {
        guard let url = URL(string: urlString),
              let dir = ArtworkStore.artworkDirectory()
        else { return nil }
        let dest = dir.appendingPathComponent("playlist-\(safeKey(playlistID)).jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest.path
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard data.count < 2_000_000,
                  let image = NSImage(data: data),
                  let normalized = normalize(image: image)
            else { return nil }
            try normalized.write(to: dest, options: .atomic)
            return dest.path
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private static func safeKey(_ key: String) -> String {
        let cleaned = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).prefix(64))
    }

    private static func normalize(image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              NSBitmapImageRep(data: tiff) != nil
        else { return nil }
        var target = image.size
        let longest = max(target.width, target.height)
        if longest > 1024, longest > 0 {
            let scale = 1024 / longest
            target = NSSize(width: target.width * scale, height: target.height * scale)
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        guard let sized = rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return sized.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
