import Foundation

/// Schema version 34 — `dictations.recovered`: marks records produced by the
/// crash-recovery path (an orphaned audio spool transcribed after the original
/// session died) so the history UI can badge them distinctly from live
/// dictations. Existing rows default to 0 (a normal live dictation).
///
/// Versioning: v34–v35 are the dictation group's reserved slots in the
/// 5-group worktree split (v23–v37 reserved overall); see `AppSchema`.
public enum DictationSchemaV34 {

    public static let version = 34

    public static let migration = Migration(
        version: DictationSchemaV34.version,
        name: "dictations_add_recovered",
        sql: """
            ALTER TABLE dictations ADD COLUMN recovered INTEGER NOT NULL DEFAULT 0;
            """
    )

    /// Applies migration v34 on top of an already-bootstrapped database.
    ///
    /// Safe to call repeatedly; `MigrationManager` skips versions already
    /// recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [DictationSchemaV34.migration])
    }
}
