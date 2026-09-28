import Foundation

/// Normalized album row, derived from track metadata.
/// Display title/artist preserve first-seen spelling; `id` is canonical.
struct Album: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var artworkPath: String?
    var releaseDate: String?
    /// Denormalized for grid sorting without a join.
    var trackCount: Int = 0
}

/// Normalized artist row, derived from track metadata.
struct Artist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artworkPath: String?
    var trackCount: Int = 0
}

/// Local playlist with explicit ordering via playlist_tracks.position.
struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
