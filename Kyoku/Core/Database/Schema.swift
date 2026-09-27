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
}
