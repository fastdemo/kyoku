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

    /// Phase 3: automation tables + download/sync linkage. Additive only.
    ///
    /// Design notes:
    /// - `sources` is the watched remote (URL + classification + display).
    /// - `sync_jobs` is the user's policy for one source (destination,
    ///   profile, schedule, removal, enabled). One source MAY feed many
    ///   jobs later, but Phase 3 creates one job per source.
    /// - `source_snapshots` stores the last resolved track list per source
    ///   (JSON array of stable entries) so change detection survives restarts.
    /// - `sync_runs` records each execution for Activity + recovery.
    /// - `attention_items` is the Needs Attention inbox (persistent).
    /// - `activity_events` is the human-readable Activity feed.
    /// - `download_tasks` gains sync linkage columns (nullable; one-off
    ///   Phase 1/2 downloads simply leave them NULL).
    static let v4tables: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL DEFAULT 'unknown',
            url TEXT NOT NULL,
            display_name TEXT NOT NULL DEFAULT '',
            artwork_path TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            last_checked_at REAL,
            last_success_at REAL,
            last_error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_jobs (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            name TEXT NOT NULL DEFAULT '',
            destination TEXT NOT NULL DEFAULT '',
            profile_id TEXT NOT NULL DEFAULT 'apple-library',
            schedule TEXT NOT NULL DEFAULT 'manual',
            removal_policy TEXT NOT NULL DEFAULT 'ask',
            enabled INTEGER NOT NULL DEFAULT 1,
            last_run_at REAL,
            last_success_at REAL,
            last_error TEXT,
            consecutive_failures INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS source_snapshots (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            snapshot_json TEXT NOT NULL DEFAULT '[]',
            track_count INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_runs (
            id TEXT PRIMARY KEY,
            sync_job_id TEXT NOT NULL REFERENCES sync_jobs(id) ON DELETE CASCADE,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL DEFAULT 'running',
            added_count INTEGER NOT NULL DEFAULT 0,
            removed_count INTEGER NOT NULL DEFAULT 0,
            changed_count INTEGER NOT NULL DEFAULT 0,
            unchanged_count INTEGER NOT NULL DEFAULT 0,
            queued_count INTEGER NOT NULL DEFAULT 0,
            downloaded_count INTEGER NOT NULL DEFAULT 0,
            failed_count INTEGER NOT NULL DEFAULT 0,
            error TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS attention_items (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            sync_job_id TEXT REFERENCES sync_jobs(id) ON DELETE CASCADE,
            source_url TEXT,
            track_url TEXT,
            task_id TEXT REFERENCES download_tasks(id) ON DELETE SET NULL,
            status TEXT NOT NULL DEFAULT 'open',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sync_job_id TEXT REFERENCES sync_jobs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_activity_time ON activity_events(created_at);",
        "CREATE INDEX IF NOT EXISTS idx_attention_status ON attention_items(status);",
        "CREATE INDEX IF NOT EXISTS idx_sync_runs_job ON sync_runs(sync_job_id);",
    ]

    /// Phase 3: download_tasks linkage. Nullable; one-off downloads NULL.
    static let v4columns: [String] = [
        "ALTER TABLE download_tasks ADD COLUMN sync_job_id TEXT REFERENCES sync_jobs(id) ON DELETE SET NULL;",
        "ALTER TABLE download_tasks ADD COLUMN sync_run_id TEXT REFERENCES sync_runs(id) ON DELETE SET NULL;",
        "ALTER TABLE download_tasks ADD COLUMN source_id TEXT REFERENCES sources(id) ON DELETE SET NULL;",
    ]
}
