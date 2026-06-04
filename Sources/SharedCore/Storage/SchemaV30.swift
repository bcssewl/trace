import Foundation

/// Schema version 30 — `projects.overrides_json`: per-project configuration
/// overrides (model + ASR route overrides, vocabulary, calendar matchers) stored
/// as a single JSON blob, mirroring the existing `projects.coach_config` column
/// pattern.
///
/// Decoded into `ProjectOverrides` and applied by `ModelRouter` /
/// `ASRRouter` (BAS-23). Existing rows default to `'{}'` → an empty override set.
///
/// Versioning: v1–v15 `SchemaV1`; v16 reserved; v17–v21 library work; v22–v28
/// reserved for sibling worktrees; v29 added `files.kind`/`files.origin` (the
/// Files/Voice-Memo batch); v30 (this file) is the same batch's Projects slot.
public enum SchemaV30 {

    public static let version = 30

    public static let migration = Migration(
        version: SchemaV30.version,
        name: "add_projects_overrides_json",
        sql: """
            ALTER TABLE projects ADD COLUMN overrides_json TEXT NOT NULL DEFAULT '{}';
            """
    )

    /// Applies migration v30 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV30.migration])
    }
}
