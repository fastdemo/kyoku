import Foundation

/// Playlist folder policy: every synced playlist downloads into its own
/// subfolder of the music root (`<Music>/<Playlist Name>/`), using the
/// remote playlist's name sanitized for the filesystem.
///
/// Rules:
/// - Sanitize `/`, `:`, and control characters → `-`; trim whitespace and
///   dots (macOS--hostile trailing dots); empty result → "Untitled Playlist".
/// - Cap at 100 characters (well under NAME_MAX, leaves room for suffixes).
/// - Collisions: when the resolved folder already exists AND belongs to a
///   different playlist (name-mismatch), append ` 2`, ` 3`, … — never
///   blindly merge into or overwrite an unrelated directory.
/// - Renames never move files automatically: renaming a playlist (or a
///   remote playlist changing name) updates the job's destination for
///   FUTURE downloads only. Existing files stay where they are; the user
///   moves them explicitly if desired. Rationale: silent bulk moves of a
///   potentially large collection violate least-surprise and can strand
///   the library index if interrupted.
enum PlaylistDestinations {
    /// Filesystem-safe folder name for a playlist title.
    static func safeFolderName(for title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Control characters + macOS/Windows-hostile separators.
        let hostile = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        name = name.components(separatedBy: hostile).joined(separator: "-")
        // Collapse repeats, trim edge dashes/dots/spaces.
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        if name.isEmpty { return "Untitled Playlist" }
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: "-. ")) }
        return name.isEmpty ? "Untitled Playlist" : name
    }

    /// Resolve the destination path for a playlist sync job. Returns "" when
    /// there is no music root (caller falls back to the root at run time).
    /// `existingDestinations` maps known destination paths → owning
    /// playlist names; used to detect collisions without touching disk
    /// (callers may pass SyncJobStore destinations).
    static func resolve(playlistName: String,
                        musicRoot: URL?,
                        existingDestinations: [String: String]? = nil,
                        access: MusicFolderAccess? = nil) -> String {
        guard let root = musicRoot ?? access?.folderURL else { return "" }
        let base = safeFolderName(for: playlistName)
        var candidate = root.appendingPathComponent(base, isDirectory: true).path
        // Collision check via known destinations first (no disk I/O), then
        // the filesystem. A folder owned by THIS playlist name is fine
        // (re-sync); owned by another name (or unknown on disk) → suffix.
        var n = 2
        while isTaken(candidate, byOtherThan: playlistName,
                      existing: existingDestinations) {
            candidate = root.appendingPathComponent("\(base) \(n)", isDirectory: true).path
            n += 1
        }
        return candidate
    }

    private static func isTaken(_ path: String, byOtherThan name: String,
                                existing: [String: String]?) -> Bool {
        if let existing, let owner = existing[path], owner != name {
            return true
        }
        var isDir: ObjCBool = false
        // On-disk folder with no recorded owner: treat as taken (never
        // merge into an unrelated directory the user created by hand).
        // Exception: empty directories are safe to adopt.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue
        else { return false }
        if let existing, existing[path] == name { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return !contents.isEmpty
    }
}
