import Foundation

/// Schema version 32 — `files.recovery_attempts`: how many times a crashed-out
/// file-batch job has been re-queued by `FileBatchController`'s start-up
/// recovery pass.
///
/// A crash mid-transcription leaves a `files` row stuck in a non-terminal
/// status (`transcribing` / `summarizing` / …) forever — the queue is in-memory
/// only. Recovery re-queues such rows, and this counter is the crash-loop
/// guard: after N attempts the row is marked `failed` with a clear,
/// user-visible reason instead of being retried again (the file itself may be
/// what crashes the app).
///
/// Versioning: v1–v15 `SchemaV1`; v16 + v23–v28 are historical ghosts (never
/// shipped — do not fill); v17–v22 the library/index work; v29–v30 the
/// Files/Projects batch; v31 `fts_reconcile_state`. v31–v33 are reserved for
/// the storage batch; v32 (this file) is its second slot.
public enum SchemaV32 {

    public static let version = 32

    public static let migration = Migration(
        version: SchemaV32.version,
        name: "add_files_recovery_attempts",
        sql: """
            ALTER TABLE files ADD COLUMN recovery_attempts INTEGER NOT NULL DEFAULT 0;
            """
    )

    /// Applies migration v32 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV32.migration])
    }
}
