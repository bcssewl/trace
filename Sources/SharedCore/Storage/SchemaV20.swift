import Foundation

/// Schema version 20 — project-scoped enrolled speaker voiceprints (BAS-11,
/// design §14.3 "Speaker Enrollment").
///
/// Cross-meeting speaker memory lets the user rename "Speaker 2" → "Sarah" once
/// and have it stick on future meetings. To do that we persist, per project, a
/// mean voiceprint per known speaker; at the next meeting's finalize the offline
/// diarizer's per-speaker embeddings are matched against this table by cosine and
/// matches above threshold get the saved name auto-applied. Everything stays on
/// device — there is no network path for these embeddings.
///
/// - `id TEXT PRIMARY KEY` — stable speaker id (UUID string); `INSERT OR REPLACE`
///   keys on it so a rename/correction updates in place.
/// - `project_id TEXT` — owning project; NULL is the Inbox/un-projected bucket
///   (matched with `IS` so NULL scoping works). Voiceprints are project-scoped so
///   the same voice can carry different names in different projects.
/// - `name TEXT NOT NULL` — the human name to auto-apply.
/// - `mean_embedding BLOB NOT NULL` — the voiceprint, packed little-endian `Float`
///   (see `Array<Float>.toBlobData()` / `init(blobData:)`).
/// - `embedding_model TEXT NOT NULL` — which embedder produced it, so a model
///   change can be detected (mismatched-dimension records are ignored at match).
/// - `last_seen INTEGER NOT NULL` — epoch seconds of the most recent meeting this
///   voice was seen in (for future LRU pruning of the memory).
/// - `created_at INTEGER NOT NULL` — epoch seconds when first enrolled.
///
/// Versioning: v1–v15 belong to `SchemaV1`; v16 reserved (Files); v17 the M19
/// bootstrap sentinel; v18 grew `playbooks`; v19 grew `kb_chunks`. v20 (this
/// file) is the next free slot. Application is idempotent via `MigrationManager`.
public enum SchemaV20 {

    public static let version = 20

    public static let migration = Migration(
        version: SchemaV20.version,
        name: "enrolled_speakers",
        sql: """
            CREATE TABLE IF NOT EXISTS enrolled_speakers (
                id              TEXT PRIMARY KEY,
                project_id      TEXT,
                name            TEXT NOT NULL,
                mean_embedding  BLOB NOT NULL,
                embedding_model TEXT NOT NULL,
                last_seen       INTEGER NOT NULL,
                created_at      INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS enrolled_speakers_project ON enrolled_speakers(project_id);
            """
    )

    /// Applies migration v20 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV20.migration])
    }
}
