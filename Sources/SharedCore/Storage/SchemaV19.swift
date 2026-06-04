import Foundation

/// Schema version 19 — unify `kb_chunks` into a typed, provenance-bearing chunk
/// store so the Library / Cross-Meeting Q&A pillar (design §9) can retrieve over
/// meeting transcripts + scratchpad notes + playbooks from a SINGLE vector index.
///
/// The base schema (`SchemaV1`, migration v8) created `kb_chunks` shaped purely
/// for playbook documents (`source_file`, `breadcrumb`, `text`, `source_sha256`).
/// Cross-meeting Q&A needs each chunk to also carry where it came from so a
/// citation can deep-link to `meeting @ timestamp` and so scope pills
/// (All projects / current project / Last 90 d / by source) filter in-memory
/// without a join. Rather than add parallel `meeting_chunks` / `note_chunks`
/// tables (three of everything to maintain), we grow the existing table with
/// nullable provenance columns; playbook rows simply leave them blank.
///
/// - `source_kind TEXT NOT NULL DEFAULT 'playbook'` — `playbook|transcript|notes|summary`.
///   Existing rows are all playbooks, so the default back-fills correctly.
/// - `project_id TEXT` — owning project for meeting-derived chunks (NULL for
///   playbooks, which are global reference material).
/// - `meeting_id TEXT` — session id for transcript/notes/summary chunks; the
///   click-through target. NULL for playbooks.
/// - `speaker TEXT` — display name(s) for a transcript chunk's speakers.
/// - `ts_seconds REAL` — start offset (seconds from meeting start) of a
///   transcript chunk; the timestamp a citation seeks to.
/// - `title TEXT` — denormalized meeting title for self-contained citation
///   rendering (avoids a `meetings` join at retrieval time).
/// - `started_at INTEGER` — denormalized meeting start (epoch seconds) so the
///   "Last 90 d" scope filter is a pure in-memory predicate on loaded chunks.
///
/// Versioning: v1–v15 belong to `SchemaV1`; v16 reserved (Files); v17 is the
/// M19 bootstrap sentinel (`SchemaV17`); v18 grew `playbooks` (`SchemaV18`).
/// v19 (this file) is the next free slot. Application is idempotent via
/// `MigrationManager`'s `_migrations` version check.
public enum SchemaV19 {

    public static let version = 19

    public static let migration = Migration(
        version: SchemaV19.version,
        name: "kb_chunks_provenance",
        sql: """
            ALTER TABLE kb_chunks ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'playbook';
            ALTER TABLE kb_chunks ADD COLUMN project_id TEXT;
            ALTER TABLE kb_chunks ADD COLUMN meeting_id TEXT;
            ALTER TABLE kb_chunks ADD COLUMN speaker TEXT;
            ALTER TABLE kb_chunks ADD COLUMN ts_seconds REAL;
            ALTER TABLE kb_chunks ADD COLUMN title TEXT;
            ALTER TABLE kb_chunks ADD COLUMN started_at INTEGER;
            CREATE INDEX IF NOT EXISTS kb_chunks_meeting ON kb_chunks(meeting_id);
            CREATE INDEX IF NOT EXISTS kb_chunks_kind ON kb_chunks(source_kind);
            """
    )

    /// Applies migration v19 on top of an already-bootstrapped database.
    ///
    /// Safe to
    /// call repeatedly; `MigrationManager` skips versions already recorded.
    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: [SchemaV19.migration])
    }
}
