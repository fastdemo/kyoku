import Foundation

/// Versioned schema. Phase 0 creates only the tables needed for
/// settings/queue scaffolding; Track/Album/etc. arrive in Phase 1-2.
enum Schema {
    static let v1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            album TEXT NOT NULL DEFAULT '',
            local_path TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS download_tasks (
            id TEXT PRIMARY KEY,
            source_url TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
    ]

    /// Phase 1: queue persistence columns + library metadata columns.
    /// Additive ALTER TABLEs only; existing installs migrate in place.
    /// New installs run v1 then v2 (idempotent by inspection).
    static let v2: [String] = [
        "ALTER TABLE download_tasks ADD COLUMN resolved_json TEXT;",
        "ALTER TABLE download_tasks ADD COLUMN last_error TEXT;",
        "ALTER TABLE download_tasks ADD COLUMN output_path TEXT;",
        "ALTER TABLE tracks ADD COLUMN album_artist TEXT NOT NULL DEFAULT '';",
        "ALTER TABLE tracks ADD COLUMN duration INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE tracks ADD COLUMN source_url TEXT;",
        "ALTER TABLE tracks ADD COLUMN cover_url TEXT;",
    ]

    /// Phase 2: richer track metadata + normalized library tables.
    /// Additive only. New tables are empty on migrate; album/artist rows
    /// are backfilled lazily by LibraryStore (derive-on-read + persist),
    /// so no data migration of existing tracks is required.
    static let v3tables: [String] = [
        """
        CREATE TABLE IF NOT EXISTS albums (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            artwork_path TEXT,
            release_date TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS artists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            artwork_path TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, track_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS playback_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            played_at REAL NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_playback_track ON playback_history(track_id);",
        "CREATE INDEX IF NOT EXISTS idx_playback_time ON playback_history(played_at);",
    ]

    /// Phase 2: new track columns. All nullable or defaulted.
    static let v3columns: [String] = [
        "ALTER TABLE tracks ADD COLUMN track_number INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE tracks ADD COLUMN disc_number INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE tracks ADD COLUMN genre TEXT;",
        "ALTER TABLE tracks ADD COLUMN release_date TEXT;",
        "ALTER TABLE tracks ADD COLUMN artwork_path TEXT;",
        "ALTER TABLE tracks ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE tracks ADD COLUMN last_played_at REAL;",
        "ALTER TABLE tracks ADD COLUMN album_id TEXT REFERENCES albums(id) ON DELETE SET NULL;",
        "ALTER TABLE tracks ADD COLUMN artist_id TEXT REFERENCES artists(id) ON DELETE SET NULL;",
    ]
}
