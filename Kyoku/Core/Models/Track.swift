import Foundation

/// Phase 1 track model: discovery metadata (album artist, duration,
/// source/cover URLs) added for the download pipeline. Lyrics, match
/// confidence, and Apple Music IDs arrive in later phases.
struct Track: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    /// Duration in seconds (from spotDL metadata).
    var duration: Int
    /// Spotify URL this track was discovered from, if any.
    var sourceURL: String?
    /// Remote artwork URL (spotDL cover_url). Cached locally in Phase 2.
    var coverURL: String?
    var localPath: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        duration: Int = 0,
        sourceURL: String? = nil,
        coverURL: String? = nil,
        localPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.sourceURL = sourceURL
        self.coverURL = coverURL
        self.localPath = localPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Rich metadata for one discovered/downloaded song, decoded from
/// `spotdl save` JSON. Field names mirror spotDL's Song.json keys so
/// schema drift shows up as a decoding miss, not silent mis-mapping.
///
/// Verified against spotdl 4.5.2 output (Phase 1 probe):
/// name, artist(s), album_name, duration (seconds), song_id, url,
/// download_url (with --preload), cover_url, year, date, track/disc
/// numbers, explicit, isrc (often empty via SpotipyFree).
struct ResolvedSong: Hashable, Sendable, Codable {
    var name: String
    var artist: String
    var artists: [String]
    var albumName: String
    var albumArtist: String
    var duration: Int
    var year: Int?
    var date: String?
    var trackNumber: Int
    var discNumber: Int
    var songID: String
    var url: String
    var downloadURL: String?
    var coverURL: String?
    var isrc: String?
    var explicit: Bool
    var lyrics: String?
    var listName: String?
    var listPosition: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case artist
        case artists
        case albumName = "album_name"
        case albumArtist = "album_artist"
        case duration
        case year
        case date
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case songID = "song_id"
        case url
        case downloadURL = "download_url"
        case coverURL = "cover_url"
        case isrc
        case explicit
        case lyrics
        case listName = "list_name"
        case listPosition = "list_position"
    }

    /// Non-empty ISRC, or nil when the provider didn't supply one.
    var normalizedISRC: String? {
        guard let isrc, !isrc.isEmpty else { return nil }
        return isrc
    }

    /// Convert to a library Track. localPath is filled in after download.
    func asTrack(localPath: String? = nil, now: Date = Date()) -> Track {
        Track(
            title: name,
            artist: artist,
            album: albumName,
            localPath: localPath,
            createdAt: now,
            updatedAt: now
        )
    }
}
