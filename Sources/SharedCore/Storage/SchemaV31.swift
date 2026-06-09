import Foundation

/// Schema version 31 — `fts_reconcile_state`: per-meeting content signatures so
/// the launch-time `StorageReconciler` can verify the FTS search index against
/// the canonical on-disk content (transcript JSONL + notes.md) without reading
/// every file on every launch.
///
/// FTS writes and content-file writes can never be atomic across the two
/// stores, so a crash between them leaves the index missing or stale rows. The
/// reconciler repairs that at boot; this table is its cheapness lever — a
/// meeting whose `mtime|size` signatures match the last verified pass is
/// skipped with two `stat` calls and zero reads.
///
/// Versioning: v1–v15 `SchemaV1`; v16 + v23–v28 are historical ghosts (never
/// shipped — do not fill); v17–v22 the library/index work; v29–v30 the
/// Files/Projects batch. v31–v33 are reserved for the storage batch; v31 (this
/// file) is its first slot.
public enum SchemaV31 {

    public static let version = 31

    public static let migration = Migration(
        version: SchemaV31.version,
        name: "create_fts_reconcile_state",
        sql: """
            CREATE TABLE fts_reconcile_state (
                meeting_id     TEXT PRIMARY KEY,
                transcript_sig TEXT NOT NULL DEFAULT '',
                notes_sig      TEXT NOT NULL DEFAULT '',
                checked_at     INTEGER NOT NULL
            );
            """
    )

    /// Applies migration v31 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV31.migration])
    }
}
