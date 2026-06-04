import Foundation

/// Schema version 17 — bootstrap sentinel.
///
/// Versions 1-14 belong to the core schema declared in `SchemaV1`. Versions
/// 15 and 16 are reserved for the M08 Dictation and M11 Files migrations
/// that ship in their own development worktrees. Version 17 is owned by
/// the M19 Build & Distribution module (this file) and adds the
/// `bootstrap_state` sentinel that `BootstrapInstaller` consults to decide
/// whether the install has already run.
public enum SchemaV17 {

    public static let version = 17

    public static let migration = Migration(
        version: SchemaV17.version,
        name: "create_bootstrap_state",
        sql: """
            CREATE TABLE bootstrap_state (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                version         INTEGER NOT NULL,
                installed_at    INTEGER NOT NULL
            );
            CREATE INDEX bootstrap_state_version ON bootstrap_state(version DESC);
            """
    )

    /// Applies migration v17 on top of an already-bootstrapped database.
    /// Idempotent — re-running this against an up-to-date database is a
    /// silent no-op via `MigrationManager`'s version check.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV17.migration])
    }
}
