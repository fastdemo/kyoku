import Foundation

/// Phase 2 track model: full library metadata. New fields are nullable
/// or defaulted so the v2→v3 migration backfills safely.
struct Track: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int
    var discNumber: Int
    var genre: String?
    /// Duration in seconds (from spotDL metadata).
    var duration: Int
    /// Release date as written by the provider ("2023-04-12", "2023", …).
    /// Kept as text: providers are inconsistent, parsing loses info.
    var releaseDate: String?
    /// Spotify URL this track was discovered from, if any.
    var sourceURL: String?
    /// Remote artwork URL (spotDL cover_url). Cached locally in Phase 2.
    var coverURL: String?
    /// Managed local artwork cache path. Nil = use embedded/file art.
    var artworkPath: String?
    var localPath: String?
    /// Plays counted only after the meaningful-play threshold (see
    /// PlaybackService.recordPlayIfEligible).
    var playCount: Int
    var lastPlayedAt: Date?
    var albumID: String?
    var artistID: String?
    var createdAt: Date
    var updatedAt: Date

    /// True when the file exists on disk right now. Refreshed by
    /// reconcile(); views use it to dim missing tracks instead of
    /// crashing playback.
    var isAvailable: Bool = true

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        trackNumber: Int = 0,
        discNumber: Int = 0,
        genre: String? = nil,
        duration: Int = 0,
        releaseDate: String? = nil,
        sourceURL: String? = nil,
        coverURL: String? = nil,
        artworkPath: String? = nil,
        localPath: String? = nil,
        playCount: Int = 0,
        lastPlayedAt: Date? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.duration = duration
        self.releaseDate = releaseDate
        self.sourceURL = sourceURL
        self.coverURL = coverURL
        self.artworkPath = artworkPath
        self.localPath = localPath
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.albumID = albumID
        self.artistID = artistID
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
    /// Precedence: ResolvedSong is primary; file tags only fill duration
    /// when the provider reports 0 (see LibraryStore.importFile).
    func asTrack(localPath: String? = nil, now: Date = Date()) -> Track {
        Track(
            title: name,
            artist: artist,
            album: albumName,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            releaseDate: date,
            sourceURL: url,
            coverURL: coverURL,
            localPath: localPath,
            createdAt: now,
            updatedAt: now
        )
    }
}
