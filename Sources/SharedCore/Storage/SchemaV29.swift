import Foundation

/// Schema version 29 — `files.kind` + `files.origin`: the file batch pipeline
/// writes *every* transcription output (drag-dropped files, watched-folder
/// imports, mic-captured voice memos, and synced iPhone Voice Memos) into the
/// one `files` table.
///
/// Until now the row didn't record *which* of those it was,
/// so the UI couldn't separate the "Files" surface from the "Voice Memos"
/// surface, and a cancelled in-flight job had to *guess* its kind from the file
/// extension (BAS-22).
///
/// `kind` mirrors `FileBatchJob.Kind` (`audio` / `video` / `voiceMemo`) and
/// `origin` mirrors `FileBatchJob.Origin` (`dragDrop` / `watchedFolder` /
/// `voiceMemosSync` / `voiceMemoCapture`). Both are persisted as text so the
/// enum raw values are the contract. Existing rows predate provenance, so they
/// default to a plain dropped audio file — the safe, most-common case.
///
/// Versioning: v1–v15 belong to `SchemaV1`; v16 reserved; v17–v19 the M19
/// library work; v20 `entry_fts`; v21 `meeting_index_state`. v22–v28 are
/// reserved for sibling worktrees (parallel batches); v29 (this file) is the
/// Files/Voice-Memo batch's reserved slot. `MigrationManager` gap-fills, so the
/// absent intermediate versions are fine.
public enum SchemaV29 {

    public static let version = 29

    public static let migration = Migration(
        version: SchemaV29.version,
        name: "add_files_kind_origin",
        sql: """
            ALTER TABLE files ADD COLUMN kind TEXT NOT NULL DEFAULT 'audio';
            ALTER TABLE files ADD COLUMN origin TEXT NOT NULL DEFAULT 'dragDrop';
            CREATE INDEX files_origin ON files(origin);
            """
    )

    /// Applies migration v29 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV29.migration])
    }
}
