import Foundation

/// Schema version 18 — per-project Coach playbook *folder* records (BAS-18).
///
/// The base schema (`SchemaV1`, migration v7) created a `playbooks` table whose
/// columns were shaped for individual indexed *documents* (`source_path`,
/// `sha256`, `indexed_at`). The Coach's per-project playbook feature instead
/// tracks user-chosen *folders*, and — because the app is sandboxed — must
/// persist a security-scoped bookmark so read access to a folder the user
/// picked survives relaunch. This migration grows the existing `playbooks`
/// table rather than adding a new one:
///
/// - `bookmark_data BLOB` — the security-scoped bookmark blob (nullable so the
///   column can be back-filled onto existing rows; folder rows always set it).
/// - `created_at INTEGER NOT NULL DEFAULT 0` — when the folder was added.
///
/// We deliberately do **not** touch `kb_chunks`/`kb_embeddings`: those tables
/// are global and scoped only by `source_file` (see `VectorSearch`'s
/// `sourceFilePrefix`), so per-project scoping lives at the folder-record layer
/// here, not on the chunk rows.
///
/// Versioning: v1–v15 belong to `SchemaV1`; v16 is reserved for the Files
/// module; v17 is the M19 bootstrap sentinel (`SchemaV17`). v18 (this file) is
/// the next free slot. Application is idempotent via `MigrationManager`'s
/// `_migrations` version check, so re-running against an up-to-date database is
/// a silent no-op.
public enum SchemaV18 {

    public static let version = 18

    public static let migration = Migration(
        version: SchemaV18.version,
        name: "add_playbook_folder_columns",
        sql: """
            ALTER TABLE playbooks ADD COLUMN bookmark_data BLOB;
            ALTER TABLE playbooks ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX IF NOT EXISTS playbooks_created_at ON playbooks(created_at DESC);
            """
    )

    /// Applies migration v18 on top of an already-bootstrapped database.
    ///
    /// Safe
    /// to call repeatedly; `MigrationManager` skips versions already recorded
    /// in `_migrations`.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV18.migration])
    }
}
