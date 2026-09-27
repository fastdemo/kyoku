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
}
