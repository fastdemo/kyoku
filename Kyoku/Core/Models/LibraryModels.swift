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
/// `sourceID` links an imported playlist to its backing Source (nil for
/// manual playlists). `artworkPath` caches remote playlist artwork locally
/// (v8); `syncJobID` links the auto-created sync job (nil for manual).
struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var sourceID: String?
    var artworkPath: String?
    var syncJobID: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String,
         sourceID: String? = nil, artworkPath: String? = nil,
         syncJobID: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.artworkPath = artworkPath
        self.syncJobID = syncJobID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
