import AVFoundation
import AppKit
import Foundation

/// Managed artwork extraction + disk cache. Single authoritative home for
/// turning embedded audio artwork into stable files the UI can render
/// cheaply (no per-cell AVFoundation parsing once extracted).
///
/// Layout: <Application Support>/Kyoku/Artwork/<key>.jpg, where key is a
/// stable content-derived name (track ID for per-track art, album ID for
/// shared album art). JPEG quality 0.85, max 1024px on the long edge —
/// plenty for grids and Now Playing, bounded disk use.
///
/// Threading: extraction is synchronous AVFoundation work; callers invoke
/// it from import (background queue worker), never from cell rendering.
/// All reads after extraction are plain file loads via ArtworkCache.
enum ArtworkStore {
    /// Extract embedded artwork from `audioURL` into the managed cache.
    /// Returns the cached file path, or nil when the file has no usable
    /// embedded artwork. Idempotent: existing cache files are reused
    /// (avoids re-extracting identical art on re-import).
    /// Never throws — ingestion must not fail on artwork.
    static func extract(audioURL: URL, key: String) -> String? {
        guard let data = embeddedData(audioURL: audioURL),
              let dir = artworkDirectory()
        else { return nil }
        let dest = dir.appendingPathComponent(safeKey(key) + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest.path
        }
        guard let image = NSImage(data: data),
              let jpeg = jpegData(image: image, maxDimension: 1024)
        else { return nil }
        do {
            try jpeg.write(to: dest, options: .atomic)
            return dest.path
        } catch {
            return nil
        }
    }

    /// Raw embedded artwork bytes (for probing in tests).
    static func embeddedData(audioURL: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        let asset = AVURLAsset(url: audioURL)
        // commonMetadata/dataValue are deprecated in macOS 13+ (async
        // load(_:) replacements), but the async variants cannot run in the
        // synchronous import path. The sync accessors still function on
        // macOS 14 (deployment target); revisit if Apple removes them.
        let items = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            withKey: AVMetadataKey.commonKeyArtwork,
            keySpace: AVMetadataKeySpace.common)
        return items.first?.dataValue
    }

    /// Managed cache directory, created on demand. Nil when unreachable
    /// (callers fall back to embedded/placeholder rendering).
    static func artworkDirectory() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            let dir = base.appendingPathComponent("Kyoku/Artwork", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    // MARK: - Private

    /// Filesystem-safe key: alphanumerics + dash, capped length. Track and
    /// album IDs are already UUID/canonical strings; this guards against
    /// exotic provider IDs.
    private static func safeKey(_ key: String) -> String {
        let cleaned = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).prefix(64))
    }

    private static func jpegData(image: NSImage, maxDimension: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              NSBitmapImageRep(data: tiff) != nil
        else { return nil }
        var target = image.size
        let longest = max(target.width, target.height)
        if longest > maxDimension, longest > 0 {
            let scale = maxDimension / longest
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
