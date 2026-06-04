import Foundation

/// Schema version 22 — `meeting_index_state`: a per-meeting `last_indexed_at`
/// stamp so the background reconcile pass can mtime-gate its disk reads (BAS-28).
///
/// Without it the reconcile either re-reads every meeting from disk to recompute
/// content SHAs, or skips any meeting that already has current-fingerprint chunks
/// (never noticing a later content edit). With a stamp it loads a meeting only
/// when the max mtime of its content files (`notes.md` / `summary.md` /
/// `transcript.*.jsonl`) is newer than the last successful index — a cheap `stat`,
/// no content read — and still re-indexes after an embedding-model change.
///
/// Versioning: v1–v15 SchemaV1; v16 reserved; v17–v19 the M19 library work; v20
/// `enrolled_speakers` (BAS-11); v21 `entry_fts` (BAS-26). v22 (this file) is the
/// next free slot.
public enum SchemaV22 {

    public static let version = 22

    public static let migration = Migration(
        version: SchemaV22.version,
        name: "create_meeting_index_state",
        sql: """
            CREATE TABLE meeting_index_state (
                meeting_id TEXT PRIMARY KEY,
                last_indexed_at INTEGER NOT NULL
            );
            """
    )

    /// Applies migration v22 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV22.migration])
    }
}
