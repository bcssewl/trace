import Foundation

/// Persists per-project enrolled speaker voiceprints — the on-device "address
/// book of voices" behind cross-meeting speaker memory (BAS-11, design §14.3).
///
/// Storage is the `enrolled_speakers` table (``SchemaV20``). Rows are scoped by
/// `project_id` (NULL = the Inbox/un-projected bucket); `upsert` keys on the
/// speaker id so a rename/correction replaces in place. Everything stays local —
/// these embeddings never leave the device — and the whole memory is wipeable via
/// ``clear(projectId:)`` / ``clearAll()`` (the user-facing "stays on your Mac"
/// control).
public actor SpeakerMemoryStore {

    private let database: SqliteDatabase
    private var schemaEnsured = false

    public init(database: SqliteDatabase) {
        self.database = database
    }

    /// Idempotently ensure the `enrolled_speakers` table exists.
    ///
    /// Run lazily on
    /// first use so the store is self-contained even if app launch hasn't
    /// separately applied ``SchemaV20`` (mirrors ``PlaybookStore``).
    public func ensureSchema() async throws {
        guard !schemaEnsured else { return }
        try await SchemaV20.bootstrap(database: database)
        schemaEnsured = true
    }

    /// Enrolled voiceprints for a project (NULL scope = Inbox), ordered by name.
    public func enrolledSpeakers(projectId: UUID?) async throws -> [EnrolledSpeaker] {
        try await ensureSchema()
        return try await database.withStatement(
            sql: """
                SELECT id, name, mean_embedding, embedding_model
                  FROM enrolled_speakers
                 WHERE project_id IS ?
                 ORDER BY name ASC
                """
        ) { stmt -> [EnrolledSpeaker] in
            try stmt.bind(optionalText: projectId?.uuidString, at: 1)
            var out: [EnrolledSpeaker] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0), let name = stmt.columnText(at: 1) else { continue }
                out.append(
                    EnrolledSpeaker(
                        id: id,
                        name: name,
                        meanEmbedding: [Float](blobData: stmt.columnBlob(at: 2)),
                        embeddingModel: stmt.columnText(at: 3) ?? ""
                    ))
            }
            return out
        }
    }

    /// Insert or replace a voiceprint (keyed by `speaker.id`), stamping
    /// `last_seen` and preserving the original `created_at` on replace.
    public func upsert(_ speaker: EnrolledSpeaker, projectId: UUID?, lastSeen: Date) async throws {
        try await ensureSchema()
        let now = Int64(lastSeen.timeIntervalSince1970)
        try await database.withStatement(
            sql: """
                INSERT INTO enrolled_speakers
                    (id, project_id, name, mean_embedding, embedding_model, last_seen, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    project_id = excluded.project_id,
                    name = excluded.name,
                    mean_embedding = excluded.mean_embedding,
                    embedding_model = excluded.embedding_model,
                    last_seen = excluded.last_seen
                """
        ) { stmt in
            try stmt.bind(text: speaker.id, at: 1)
            try stmt.bind(optionalText: projectId?.uuidString, at: 2)
            try stmt.bind(text: speaker.name, at: 3)
            try stmt.bind(data: speaker.meanEmbedding.toBlobData(), at: 4)
            try stmt.bind(text: speaker.embeddingModel, at: 5)
            try stmt.bind(int64: now, at: 6)
            try stmt.bind(int64: now, at: 7)
            _ = try stmt.step()
        }
    }

    /// Persist a batch of reconciler upserts under one project scope.
    public func upsert(_ speakers: [EnrolledSpeaker], projectId: UUID?, lastSeen: Date) async throws {
        for speaker in speakers {
            try await upsert(speaker, projectId: projectId, lastSeen: lastSeen)
        }
    }

    /// Forget every voiceprint for one project (NULL scope = Inbox).
    public func clear(projectId: UUID?) async throws {
        try await ensureSchema()
        try await database.withStatement(
            sql: "DELETE FROM enrolled_speakers WHERE project_id IS ?"
        ) { stmt in
            try stmt.bind(optionalText: projectId?.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    /// Forget every voiceprint across all projects.
    public func clearAll() async throws {
        try await ensureSchema()
        try await database.exec(sql: "DELETE FROM enrolled_speakers")
    }

    /// Total enrolled voiceprints across all scopes (for the settings summary).
    public func totalCount() async throws -> Int {
        try await ensureSchema()
        return try await database.scalarInt(sql: "SELECT COUNT(*) FROM enrolled_speakers")
    }

    /// The finalize-time seam: load the project's voiceprints, reconcile against
    /// this meeting's per-`remote_N` embeddings + the user's renames
    /// (``SpeakerMemoryReconciler``), persist the resulting upserts, and return
    /// the auto-name assignments (`remote_N` → name) to apply to the transcript.
    @discardableResult
    public func reconcileAndPersist(
        speakerEmbeddings: [String: [Float]],
        sessionNames: [String: String],
        projectId: UUID?,
        embeddingModel: String,
        lastSeen: Date,
        threshold: Float = SpeakerEnrollment.defaultThreshold,
        makeID: @Sendable () -> String = { UUID().uuidString }
    ) async throws -> [String: String] {
        let enrolled = try await enrolledSpeakers(projectId: projectId)
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: speakerEmbeddings,
            sessionNames: sessionNames,
            enrolled: enrolled,
            embeddingModel: embeddingModel,
            threshold: threshold,
            makeID: makeID
        )
        try await upsert(outcome.upserts, projectId: projectId, lastSeen: lastSeen)
        return outcome.nameAssignments
    }
}
