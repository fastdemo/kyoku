import Foundation

/// Phase 0 track model. Deliberately small — grows in Phase 1/2
/// (ISRC, lyrics, match confidence, Apple Music IDs, etc.).
struct Track: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var localPath: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "",
        album: String = "",
        localPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.localPath = localPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
