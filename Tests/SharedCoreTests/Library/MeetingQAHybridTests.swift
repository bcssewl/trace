import XCTest

@testable import SharedCore

final class MeetingQAHybridTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var cache: KbCache!
    let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("qahybrid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("qa.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        try await SchemaV22.bootstrap(database: db)
        cache = KbCache(db: db)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - KbCache provenance + meeting scoping

    func testProvenanceRoundTrip() async throws {
        let chunk = KbChunk(
            sourceFile: "meeting/m1/transcript", breadcrumb: "Q2 · 00:05",
            text: "You: pricing talk", sourceSha256: "shaT",
            sourceKind: .transcript, projectId: "P1", meetingId: "m1",
            speaker: "You, Speaker 1", tsSeconds: 5.0, title: "Q2 Strategy",
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        try await cache.upsert(
            chunk: chunk,
            embedding: KbEmbedding(chunkId: chunk.id, vector: [1, 0, 0], configFingerprint: cfg.fingerprint),
            config: cfg
        )
        let loaded = try await cache.loadValid(config: cfg)
        XCTAssertEqual(loaded.count, 1)
        let c = loaded[0].0
        XCTAssertEqual(c.sourceKind, .transcript)
        XCTAssertEqual(c.projectId, "P1")
        XCTAssertEqual(c.meetingId, "m1")
        XCTAssertEqual(c.speaker, "You, Speaker 1")
        XCTAssertEqual(c.tsSeconds, 5.0)
        XCTAssertEqual(c.title, "Q2 Strategy")
        XCTAssertEqual(c.startedAt?.timeIntervalSince1970, 1000)
    }

    func testDeleteByMeetingIsScoped() async throws {
        try await upsertBare("meeting/m1/transcript", sha: "s1", meetingId: "m1")
        try await upsertBare("meeting/m2/transcript", sha: "s2", meetingId: "m2")

        let sigs = try await cache.indexedSignatures(meetingId: "m1")
        XCTAssertEqual(sigs, ["meeting/m1/transcript|s1|\(cfg.fingerprint)"])

        try await cache.deleteByMeeting(meetingId: "m1")
        let after = try await cache.indexedSignatures(meetingId: "m1")
        XCTAssertTrue(after.isEmpty)
        // The other meeting is untouched.
        let remaining = try await cache.loadValid(config: cfg)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - VectorSearch scope predicate

    func testScopedTopKFiltersByPredicate() async throws {
        try await upsertBare("meeting/m1/transcript", sha: "s1", meetingId: "m1", kind: .transcript, vector: [1, 0, 0])
        try await upsertBare("play/sales.md", sha: "s2", meetingId: nil, kind: .playbook, vector: [1, 0, 0])
        let search = VectorSearch(cache: cache, config: cfg)

        let all = try await search.topK(query: [1, 0, 0], k: 10)
        XCTAssertEqual(all.count, 2)

        let transcriptsOnly = try await search.topK(query: [1, 0, 0], k: 10, where: { $0.sourceKind == .transcript })
        XCTAssertEqual(transcriptsOnly.count, 1)
        XCTAssertEqual(transcriptsOnly.first?.chunk.meetingId, "m1")
    }

    // MARK: - MeetingChunkIndexer

    func testIndexerEmbedsProvenanceThenSkipsUnchanged() async throws {
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg, task: .embeddingsIndex)
        let indexer = MeetingChunkIndexer(cache: cache, embedder: embedder, config: cfg)

        let meeting = makeSavedMeeting(
            id: "session_idx",
            utterances: [
                Utterance(t: 0, speaker: .you, text: "hi everyone", conf: 0.9),
                Utterance(
                    t: 4, speaker: .other(id: "remote_1"), text: "let's discuss pricing and retention targets",
                    conf: 0.9),
            ],
            notes: "## Action items\n\nbrex numbers due thursday"
        )

        let r1 = try await indexer.index(meeting: meeting)
        XCTAssertFalse(r1.skipped)
        XCTAssertGreaterThan(r1.embedded, 0)

        let loaded = try await cache.loadValid(config: cfg)
        XCTAssertTrue(
            loaded.contains {
                $0.0.sourceKind == .transcript && $0.0.meetingId == "session_idx" && $0.0.tsSeconds != nil
            })
        XCTAssertTrue(loaded.contains { $0.0.sourceKind == .notes && $0.0.meetingId == "session_idx" })

        // Re-indexing unchanged content embeds nothing.
        let r2 = try await indexer.index(meeting: meeting)
        XCTAssertTrue(r2.skipped)
        XCTAssertEqual(r2.embedded, 0)

        // Changing notes re-indexes; old rows are purged (still exactly 2 sources).
        let changed = makeSavedMeeting(
            id: "session_idx",
            utterances: meeting.utterances,
            notes: "## Action items\n\nbrex numbers due FRIDAY now"
        )
        let r3 = try await indexer.index(meeting: changed)
        XCTAssertFalse(r3.skipped)
        let sigs = try await cache.indexedSignatures(meetingId: "session_idx")
        XCTAssertEqual(sigs.count, 2)
    }

    func testNotesChangeReembedsOnlyNotesNotTranscript() async throws {
        // BAS-28 per-source reindex: editing notes must NOT re-embed the transcript.
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg, task: .embeddingsIndex)
        let indexer = MeetingChunkIndexer(cache: cache, embedder: embedder, config: cfg)

        let meeting = makeSavedMeeting(
            id: "session_ps",
            utterances: [Utterance(t: 0, speaker: .you, text: "discuss pricing and retention", conf: 0.9)],
            notes: "first notes body long enough to chunk"
        )
        _ = try await indexer.index(meeting: meeting)
        let before = try await cache.loadValid(config: cfg)
        let transcriptBefore = Set(before.filter { $0.0.sourceKind == .transcript }.map(\.0.id))
        let notesBefore = Set(before.filter { $0.0.sourceKind == .notes }.map(\.0.id))
        XCTAssertFalse(transcriptBefore.isEmpty)
        XCTAssertFalse(notesBefore.isEmpty)

        let changed = makeSavedMeeting(
            id: "session_ps", utterances: meeting.utterances,
            notes: "second totally different notes body long enough to chunk"
        )
        let report = try await indexer.index(meeting: changed)
        XCTAssertFalse(report.skipped)

        let after = try await cache.loadValid(config: cfg)
        let transcriptAfter = Set(after.filter { $0.0.sourceKind == .transcript }.map(\.0.id))
        let notesAfter = Set(after.filter { $0.0.sourceKind == .notes }.map(\.0.id))
        // Transcript rows untouched (same chunk ids → not re-embedded).
        XCTAssertEqual(transcriptAfter, transcriptBefore)
        // Notes rows replaced (new chunk ids → re-embedded).
        XCTAssertNotEqual(notesAfter, notesBefore)
        XCTAssertFalse(notesAfter.isEmpty)
    }

    func testIndexUsesLiveSpeakerNameOverrides() async throws {
        // BAS-28: per-session renames passed at the finalize seam appear in
        // transcript-chunk provenance instead of the default "Speaker N".
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg, task: .embeddingsIndex)
        let indexer = MeetingChunkIndexer(cache: cache, embedder: embedder, config: cfg)

        let meeting = makeSavedMeeting(
            id: "session_sp",
            utterances: [
                Utterance(t: 0, speaker: .other(id: "remote_1"), text: "lets discuss pricing and retention", conf: 0.9)
            ]
        )
        _ = try await indexer.index(meeting: meeting, speakerNames: ["remote_1": "Sarah"])
        let loaded = try await cache.loadValid(config: cfg)
        let transcript = loaded.first { $0.0.sourceKind == .transcript }
        XCTAssertEqual(transcript?.0.speaker, "Sarah")
    }

    func testIndexStampsLastIndexedAt() async throws {
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg, task: .embeddingsIndex)
        let indexer = MeetingChunkIndexer(cache: cache, embedder: embedder, config: cfg)
        let meeting = makeSavedMeeting(
            id: "session_st",
            utterances: [Utterance(t: 0, speaker: .you, text: "pricing discussion", conf: 0.9)]
        )
        _ = try await indexer.index(meeting: meeting)
        let stamp = try await cache.lastIndexedAt(meetingId: "session_st")
        XCTAssertNotNil(stamp)
    }

    // MARK: - QASearchPipeline end-to-end (hybrid)

    func testAskProducesCitedAnswerAnchoredToMeeting() async throws {
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        await router.register(
            provider: StubLLMProvider(
                answer: "Sarah agreed to hold pricing until retention improves [1].", model: "stub-claude"
            ))

        // Index a meeting (dense arm).
        let indexEmbedder = EmbeddingClient(router: router, config: cfg, task: .embeddingsIndex)
        let indexer = MeetingChunkIndexer(cache: cache, embedder: indexEmbedder, config: cfg)
        let meeting = makeSavedMeeting(
            id: "session_qa", title: "Q2 Strategy",
            utterances: [
                Utterance(
                    t: 188, speaker: .other(id: "remote_1"),
                    text: "happy to sign off on holding at five hundred until retention improves", conf: 0.95),
                Utterance(t: 200, speaker: .you, text: "great, pricing stays then", conf: 0.95),
            ]
        )
        _ = try await indexer.index(meeting: meeting)

        // Lexical arm needs a meetings row (for the JOIN) + an FTS row.
        try await insertProject(id: "P1", name: "Optivise")
        try await insertMeetingRow(id: "session_qa", projectId: "P1", title: "Q2 Strategy", startedAt: 1_700_000_000)
        try await insertTranscriptFts(
            meetingId: "session_qa", speaker: "remote_1",
            text: "happy to sign off on holding at five hundred until retention improves", t: 188
        )

        let store = LibraryStore(db: db, vectorSearch: VectorSearch(cache: cache, config: cfg))
        let pipeline = QASearchPipeline(
            embedder: EmbeddingClient(router: router, config: cfg, task: .embeddingsLive),
            vectorSearch: VectorSearch(cache: cache, config: cfg),
            reranker: nil, router: router, lexical: store
        )

        let answer = try await pipeline.ask(question: "what did sarah commit about pricing and retention?")
        XCTAssertTrue(answer.answer.contains("[1]"))
        XCTAssertEqual(answer.model, "stub-claude")
        XCTAssertGreaterThan(answer.citations.count, 0)
        XCTAssertTrue(answer.citations.contains { $0.passage.meetingId == "session_qa" })
        XCTAssertTrue(answer.citations.contains { $0.passage.tsSeconds != nil })
        XCTAssertTrue(answer.validation.isValid)
    }

    func testAskWithNoIndexReturnsGracefulEmptyAnswer() async throws {
        let router = ModelRouter()
        await router.register(provider: BagOfWordsEmbeddingProvider())
        await router.register(provider: StubLLMProvider(answer: "unused"))
        let store = LibraryStore(db: db, vectorSearch: VectorSearch(cache: cache, config: cfg))
        let pipeline = QASearchPipeline(
            embedder: EmbeddingClient(router: router, config: cfg, task: .embeddingsLive),
            vectorSearch: VectorSearch(cache: cache, config: cfg),
            reranker: nil, router: router, lexical: store
        )
        let answer = try await pipeline.ask(question: "anything indexed?")
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertTrue(answer.validation.isValid)
        XCTAssertTrue(answer.answer.lowercased().contains("no indexed"))
    }

    // MARK: - Pure fusion + scope logic

    func testReciprocalRankFusionDedupesByMeetingRegion() {
        let dense = [
            RetrievedPassage(
                id: "dense:a", kind: .transcript, text: "x", meetingId: "m1", tsSeconds: 10, score: 0.9, origin: .dense),
            RetrievedPassage(
                id: "dense:b", kind: .transcript, text: "y", meetingId: "m2", tsSeconds: 0, score: 0.5, origin: .dense),
        ]
        let lexical = [
            // Same meeting + same ~minute as dense:a → collapses to one citation.
            RetrievedPassage(
                id: "lex:1", kind: .transcript, text: "x2", meetingId: "m1", tsSeconds: 12, score: 0, origin: .lexical)
        ]
        let fused = QASearchPipeline.reciprocalRankFusion(dense: dense, lexical: lexical)
        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused.first?.meetingId, "m1")  // boosted by appearing in both arms
        XCTAssertEqual(fused.first?.origin, .dense)  // dense kept as representative
    }

    func testScopeFilterRespectsProjectRecencyKeepsPlaybooks() {
        let now = Date()
        let recent = KbChunk(
            sourceFile: "meeting/m1/transcript", breadcrumb: "", text: "a", sourceSha256: "s",
            sourceKind: .transcript, projectId: "P1", meetingId: "m1", startedAt: now)
        let old = KbChunk(
            sourceFile: "meeting/m2/transcript", breadcrumb: "", text: "b", sourceSha256: "s",
            sourceKind: .transcript, projectId: "P1", meetingId: "m2", startedAt: now.addingTimeInterval(-200 * 86_400))
        let otherProject = KbChunk(
            sourceFile: "meeting/m3/transcript", breadcrumb: "", text: "c", sourceSha256: "s",
            sourceKind: .transcript, projectId: "P2", meetingId: "m3", startedAt: now)
        let playbook = KbChunk(
            sourceFile: "play/s.md", breadcrumb: "P", text: "d", sourceSha256: "s", sourceKind: .playbook)

        let filter = QASearchPipeline.makeScopeFilter(LibrarySearchScope(projectIds: ["P1"], lastNDays: 90))
        XCTAssertNotNil(filter)
        XCTAssertTrue(filter!(recent))
        XCTAssertFalse(filter!(old))  // too old
        XCTAssertFalse(filter!(otherProject))  // wrong project
        XCTAssertTrue(filter!(playbook))  // playbooks are global reference
    }

    func testUnconstrainedScopeMakesNoFilter() {
        XCTAssertNil(QASearchPipeline.makeScopeFilter(LibrarySearchScope()))
    }

    // MARK: - Helpers

    private func upsertBare(
        _ sourceFile: String, sha: String, meetingId: String?,
        kind: KbChunk.SourceKind = .transcript, vector: [Float] = [1, 0, 0]
    ) async throws {
        let chunk = KbChunk(
            sourceFile: sourceFile, breadcrumb: "", text: "t", sourceSha256: sha,
            sourceKind: kind, meetingId: meetingId
        )
        try await cache.upsert(
            chunk: chunk,
            embedding: KbEmbedding(chunkId: chunk.id, vector: vector, configFingerprint: cfg.fingerprint),
            config: cfg
        )
    }

    private func insertProject(id: String, name: String) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO projects (id, name, indicator_color, created_at, updated_at)
                VALUES (?, ?, '#000', 0, 0)
                """
        ) { stmt in
            try stmt.bind(text: id, at: 1)
            try stmt.bind(text: name, at: 2)
            _ = try stmt.step()
        }
    }

    private func insertMeetingRow(id: String, projectId: String, title: String, startedAt: Int64) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO meetings (id, project_id, title, started_at, session_dir_path)
                VALUES (?, ?, ?, ?, ?)
                """
        ) { stmt in
            try stmt.bind(text: id, at: 1)
            try stmt.bind(text: projectId, at: 2)
            try stmt.bind(text: title, at: 3)
            try stmt.bind(int64: startedAt, at: 4)
            try stmt.bind(text: "/tmp/\(id)", at: 5)
            _ = try stmt.step()
        }
    }

    private func insertTranscriptFts(meetingId: String, speaker: String, text: String, t: Double) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp) VALUES (?, ?, ?, ?)
                """
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(text: speaker, at: 2)
            try stmt.bind(text: text, at: 3)
            try stmt.bind(double: t, at: 4)
            _ = try stmt.step()
        }
    }
}
