import Foundation

/// The single application schema: every migration across all `SchemaV*` files,
/// applied through one idempotent, gap-filling `MigrationManager.apply`.
///
/// Call `AppSchema.bootstrap(database:)` from app launch (and tests) instead of
/// hand-listing individual `SchemaVN.bootstrap` calls. `MigrationManager.apply`
/// runs any migration whose version isn't yet recorded — in order, out-of-order
/// safe — so the applied set can never drift between call sites (the old
/// per-site lists had already diverged: a fallback path silently skipped v17).
public enum AppSchema {
    /// All migrations, lowest version first. v16 is reserved (Files module ships
    /// it in its own worktree); `apply` gap-fills, so its absence is fine.
    public static let allMigrations: [Migration] =
        SchemaV1.migrations
        + [
            SchemaV17.migration, SchemaV18.migration, SchemaV19.migration,
            SchemaV20.migration,  // enrolled_speakers (BAS-11)
            SchemaV21.migration,  // entry_fts (BAS-26)
            SchemaV22.migration,  // meeting_index_state (BAS-28)
            SchemaV29.migration,  // files (BAS-22)
            SchemaV30.migration,  // project overrides (BAS-23)
        ]

    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: allMigrations)
    }
}
