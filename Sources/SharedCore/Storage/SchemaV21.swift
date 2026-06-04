import Foundation

/// Schema version 21 — `entry_fts`: a single FTS5 index over the "document-like"
/// library sources (dictations, transcribed files, voice memos) so Library
/// keyword search reaches every captured surface, not just meeting transcripts +
/// notes (design §9.2; BAS-26).
///
/// Meetings keep their granular per-utterance `transcript_fts` + per-meeting
/// `notes_fts`. These three sources are one text blob per item, so this table is
/// one row per item. Provenance columns are `UNINDEXED` (stored + returnable, not
/// tokenized); only `text` is searchable. `sig` is a cheap content-change
/// signature (a text SHA for in-DB dictations, `mtime|size` for on-disk file /
/// voice-memo transcripts) so the reconciler skips unchanged items without
/// re-reading them.
///
/// Versioning: v1–v15 belong to `SchemaV1`; v16 reserved (Files); v17–v19 the M19
/// library work; v20 grew `enrolled_speakers` (BAS-11). v21 (this file) is the
/// next free slot. Application is idempotent via `MigrationManager`'s version check.
public enum SchemaV21 {

    public static let version = 21

    public static let migration = Migration(
        version: SchemaV21.version,
        name: "create_entry_fts",
        sql: """
            CREATE VIRTUAL TABLE entry_fts USING fts5(
                item_id UNINDEXED,
                source UNINDEXED,
                project_id UNINDEXED,
                title UNINDEXED,
                started_at UNINDEXED,
                sig UNINDEXED,
                text
            );
            """
    )

    /// Applies migration v21 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV21.migration])
    }
}
