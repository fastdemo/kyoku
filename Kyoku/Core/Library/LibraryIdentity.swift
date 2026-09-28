import Foundation

/// Canonical identity for library entities.
///
/// Identity rule: nim.id = lowercase(trimmed display name), with runs of
/// whitespace collapsed to a single space. Empty strings map to "" and
/// must never be persisted as album/artist rows (callers skip them).
///
/// This keeps "YOASOBI", "YOASOBI " and "yoasobi" on one row while the
/// display name preserves the first-seen spelling. Deliberately NOT fuzzy:
/// "The Beatles" vs "Beatles" stay separate — over-merging is worse than
/// a duplicate the user can see. Revisit only with explicit user merge UI.
enum LibraryIdentity {
    static func canonical(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Album identity combines album title + album artist so two artists
    /// with same-named albums don't collide. Falls back to track artist
    /// when albumArtist is blank (matches display fallback).
    static func albumID(title: String, albumArtist: String, artist: String) -> String {
        let effectiveArtist = albumArtist.isEmpty ? artist : albumArtist
        return canonical(title) + "\u{1F}" + canonical(effectiveArtist)
    }
}
