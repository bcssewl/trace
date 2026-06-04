import XCTest

@testable import SharedCore

final class EmbeddingConfigTests: XCTestCase {
    private func cfg(
        _ provider: String, _ url: String?, _ model: String, _ norm: EmbeddingConfig.Normalization
    ) -> EmbeddingConfig {
        EmbeddingConfig(
            provider: provider, baseURL: url.flatMap(URL.init(string:)),
            model: model, normalization: norm
        )
    }

    func testFingerprintLowercased() {
        XCTAssertEqual(
            cfg("Ollama", "HTTP://LOCALHOST:11434", "NOMIC-EMBED-TEXT", .unitL2).fingerprint,
            "ollama|http://localhost:11434|nomic-embed-text|n1"
        )
    }

    func testFingerprintWithoutBaseURL() {
        XCTAssertEqual(
            cfg("appleFM", nil, "embed-default", .unitL2).fingerprint,
            "applefm||embed-default|n1"
        )
    }

    func testFingerprintNoneNormalization() {
        XCTAssertEqual(
            cfg("openai", "https://api.openai.com/v1", "text-embedding-3-small", .none).fingerprint,
            "openai|https://api.openai.com/v1|text-embedding-3-small|n0"
        )
    }
}

final class MarkdownChunkerTests: XCTestCase {
    private func chunk(_ md: String, file: String = "x.md") -> [MarkdownChunker.Output] {
        MarkdownChunker.chunk(markdown: md, sourceFile: file)
    }

    func testStripsYamlFrontmatter() {
        let out = chunk("---\ntitle: Sample\n---\n# Heading\n\nBody content here.")
        XCTAssertFalse(out.contains { $0.text.contains("title: Sample") })
        XCTAssertTrue(out.contains { $0.text.contains("Body content here.") })
    }

    func testBreadcrumbsForHierarchy() {
        let out = chunk(
            """
            # Sales
            ## Pricing
            Pricing body text long enough to be a chunk on its own.
            ### Tiers
            Tier body text.
            """)
        let crumbs = out.map(\.breadcrumb)
        XCTAssertTrue(crumbs.contains { $0.hasPrefix("Sales > Pricing") })
    }

    func testBreadcrumbResetsOnSibling() {
        let out = chunk("# Top\n## A\nBody A long enough.\n## B\nBody B long enough.")
        XCTAssertFalse(out.contains { $0.breadcrumb == "Top > A > B" })
    }

    func testLongSectionSplitsWithOverlap() {
        let body = (1...700).map { "w\($0)" }.joined(separator: " ")
        let out = chunk("# Top\n\n## Long\n\n\(body)")
        XCTAssertGreaterThanOrEqual(out.count, 2)
        let firstTail = out[0].text.split(whereSeparator: \.isWhitespace).suffix(100)
        let secondHead = out[1].text.split(whereSeparator: \.isWhitespace).prefix(120)
        let overlap = Set(firstTail.map(String.init)).intersection(Set(secondHead.map(String.init)))
        XCTAssertGreaterThanOrEqual(overlap.count, 50)
    }

    func testNoHeadersFallbackChunks() {
        let body = (1...1200).map { "w\($0)" }.joined(separator: " ")
        let out = chunk(body)
        XCTAssertGreaterThanOrEqual(out.count, 3)
        for c in out { XCTAssertEqual(c.breadcrumb, "") }
    }

    func testSourceFilePropagates() {
        let out = chunk("# H\nBody.", file: "playbook/sales.md")
        for c in out { XCTAssertEqual(c.sourceFile, "playbook/sales.md") }
    }
}

final class KbCacheTests: XCTestCase {
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
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kbcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("kb.sqlite"))
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

    private func chunk(_ file: String, _ sha: String, _ text: String = "x") -> KbChunk {
        KbChunk(sourceFile: file, breadcrumb: "Sec", text: text, sourceSha256: sha)
    }

    private func emb(_ c: KbChunk, _ v: [Float], cfg: EmbeddingConfig? = nil) -> KbEmbedding {
        KbEmbedding(chunkId: c.id, vector: v, configFingerprint: (cfg ?? self.cfg).fingerprint)
    }

    func testFreshFileNeedsEmbedding() async throws {
        let c = chunk("a.md", "abc")
        let needs = try await cache.shouldEmbed(chunk: c, config: cfg)
        XCTAssertTrue(needs)
    }

    func testCachedFileSkipsEmbedding() async throws {
        let c = chunk("a.md", "abc")
        try await cache.upsert(chunk: c, embedding: emb(c, [1, 0, 0]), config: cfg)
        let needs = try await cache.shouldEmbed(chunk: c, config: cfg)
        XCTAssertFalse(needs)
    }

    func testChangedShaRequiresReembed() async throws {
        let v1 = chunk("a.md", "abc")
        try await cache.upsert(chunk: v1, embedding: emb(v1, [1, 0, 0]), config: cfg)
        let v2 = chunk("a.md", "def")
        let needs = try await cache.shouldEmbed(chunk: v2, config: cfg)
        XCTAssertTrue(needs)
    }

    func testFingerprintChangeInvalidates() async throws {
        let c = chunk("a.md", "abc")
        try await cache.upsert(chunk: c, embedding: emb(c, [1, 0, 0]), config: cfg)
        let alt = EmbeddingConfig(
            provider: "openai", baseURL: URL(string: "https://api.openai.com/v1"),
            model: "text-embedding-3-small", normalization: .unitL2
        )
        let needs = try await cache.shouldEmbed(chunk: c, config: alt)
        XCTAssertTrue(needs)
    }

    func testPruneObsoleteRemovesAllWhenKeepingEmpty() async throws {
        let c = chunk("a.md", "abc")
        try await cache.upsert(chunk: c, embedding: emb(c, [1, 0, 0]), config: cfg)
        try await cache.pruneObsolete(keeping: [])
        let count = try await cache.cachedChunkCount(file: "a.md")
        XCTAssertEqual(count, 0)
    }

    func testLoadValidReturnsMatchingConfigOnly() async throws {
        let c = chunk("a.md", "abc")
        try await cache.upsert(chunk: c, embedding: emb(c, [1, 0, 0]), config: cfg)
        let loaded = try await cache.loadValid(config: cfg)
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: BAS-28 — last_indexed_at + per-source delete

    func testLastIndexedAtRoundTrips() async throws {
        let initial = try await cache.lastIndexedAt(meetingId: "m1")
        XCTAssertNil(initial)
        try await cache.setLastIndexedAt(meetingId: "m1", at: 12_345)
        let stored = try await cache.lastIndexedAt(meetingId: "m1")
        XCTAssertEqual(stored, 12_345)
        // Upsert replaces, doesn't duplicate.
        try await cache.setLastIndexedAt(meetingId: "m1", at: 99_999)
        let updated = try await cache.lastIndexedAt(meetingId: "m1")
        XCTAssertEqual(updated, 99_999)
    }

    private func meetingChunk(_ file: String, meetingId: String, kind: KbChunk.SourceKind) -> KbChunk {
        KbChunk(
            sourceFile: file, breadcrumb: "", text: "t", sourceSha256: "sha",
            sourceKind: kind, meetingId: meetingId
        )
    }

    func testDeleteByMeetingSourceRemovesOnlyThatSource() async throws {
        let transcript = meetingChunk("meeting/m1/transcript", meetingId: "m1", kind: .transcript)
        let notes = meetingChunk("meeting/m1/notes", meetingId: "m1", kind: .notes)
        try await cache.upsert(chunk: transcript, embedding: emb(transcript, [1, 0, 0]), config: cfg)
        try await cache.upsert(chunk: notes, embedding: emb(notes, [0, 1, 0]), config: cfg)

        try await cache.deleteByMeetingSource(meetingId: "m1", sourceFile: "meeting/m1/notes")

        let transcriptCount = try await cache.cachedChunkCount(file: "meeting/m1/transcript")
        let notesCount = try await cache.cachedChunkCount(file: "meeting/m1/notes")
        XCTAssertEqual(transcriptCount, 1)
        XCTAssertEqual(notesCount, 0)
    }
}

final class CitationEnforcerTests: XCTestCase {
    func testValidAnswerWithCitations() {
        let v = CitationEnforcer.validate(
            answer: "Pricing tiers are described in [1] and supported by [2].",
            contextChunkCount: 3
        )
        XCTAssertTrue(v.isValid)
        XCTAssertEqual(v.citedIndices, [1, 2])
    }

    func testRejectsOutOfRangeCitations() {
        let v = CitationEnforcer.validate(
            answer: "See [1] and [9] for details.",
            contextChunkCount: 3
        )
        XCTAssertFalse(v.isValid)
        XCTAssertEqual(v.outOfRangeIndices, [9])
    }

    func testRejectsZeroCitationsWhenRequired() {
        let v = CitationEnforcer.validate(
            answer: "No citations here.",
            contextChunkCount: 3
        )
        XCTAssertFalse(v.isValid)
    }
}

final class LibraryStoreTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var store: LibraryStore!
    let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("libstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("lib.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        let cache = KbCache(db: db)
        let search = VectorSearch(cache: cache, config: cfg)
        store = LibraryStore(db: db, vectorSearch: search)
        try await seed()
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    func testListMeetingsByProject() async throws {
        let items = try await store.listMeetings(
            project: "P_OPTI", filter: LibraryFilter(), sort: .startedAtDescending
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.title, "Meeting B")
    }

    func testListDictationsSynthesizesTitleFromCleanedText() async throws {
        let items = try await store.listDictations(
            project: nil, filter: LibraryFilter(), sort: .startedAtDescending
        )
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.contains { $0.title.hasPrefix("D1") })
    }

    func testListFilesUsesCreatedAtAsStartedAt() async throws {
        let items = try await store.listFiles(
            project: nil, filter: LibraryFilter(), sort: .startedAtDescending
        )
        XCTAssertGreaterThanOrEqual(items.count, 2)
    }

    func testListFilesFilteredByQuery() async throws {
        let items = try await store.listFiles(
            project: nil, filter: LibraryFilter(query: "interview"),
            sort: .startedAtDescending
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "podcast-interview.m4a")
    }

    func testRecentItemsAcrossSources() async throws {
        let recent = try await store.recentItems(limit: 5)
        XCTAssertGreaterThanOrEqual(recent.count, 4)
        for i in 0..<(recent.count - 1) {
            XCTAssertGreaterThanOrEqual(recent[i].startedAt, recent[i + 1].startedAt)
        }
    }

    func testKeywordSearchHitsTranscript() async throws {
        let hits = try await store.searchKeyword(query: "pricing", scope: LibrarySearchScope())
        XCTAssertGreaterThan(hits.count, 0)
        XCTAssertTrue(hits.contains { $0.snippet.lowercased().contains("pricing") })
    }

    func testKeywordSearchScopeFilter() async throws {
        let all = try await store.searchKeyword(query: "pricing", scope: LibrarySearchScope())
        let projOnly = try await store.searchKeyword(
            query: "pricing",
            scope: LibrarySearchScope(projectIds: ["P_OPTI"])
        )
        XCTAssertLessThanOrEqual(projOnly.count, all.count)
        XCTAssertTrue(projOnly.allSatisfy { $0.projectId == "P_OPTI" })
    }

    private func seed() async throws {
        try await insertProjects()
        try await insertMeetings()
        try await insertDictations()
        try await insertFiles()
        try await insertVoiceMemos()
        try await insertFtsRows()
    }

    private func insertProjects() async throws {
        for (id, name) in [("P_OPTI", "Optivise"), ("P_PERS", "Personal")] {
            try await db.withStatement(
                sql:
                    "INSERT INTO projects (id, name, indicator_color, created_at, updated_at) VALUES (?, ?, '#000', 0, 0)"
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                try stmt.bind(text: name, at: 2)
                _ = try stmt.step()
            }
        }
    }

    private func insertMeetings() async throws {
        let rows: [(String, String, String, Int64)] = [
            ("M1", "P_OPTI", "Meeting A", 100),
            ("M2", "P_OPTI", "Meeting B", 200),
        ]
        for (id, proj, title, ts) in rows {
            try await db.withStatement(
                sql: """
                    INSERT INTO meetings (id, project_id, title, started_at, session_dir_path)
                    VALUES (?, ?, ?, ?, ?)
                    """
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                try stmt.bind(text: proj, at: 2)
                try stmt.bind(text: title, at: 3)
                try stmt.bind(int64: ts, at: 4)
                try stmt.bind(text: "/tmp/\(id)", at: 5)
                _ = try stmt.step()
            }
        }
    }

    private func insertDictations() async throws {
        let rows: [(String, String, String, Int64)] = [
            ("D1", "P_OPTI", "D1 cleaned text", 110),
            ("D2", "P_PERS", "D2 cleaned text", 180),
            ("D3", "P_OPTI", "D3 cleaned text", 220),
        ]
        for (id, proj, cleaned, ts) in rows {
            try await db.withStatement(
                sql: """
                    INSERT INTO dictations (id, project_id, raw_text, cleaned_text, duration_ms, started_at)
                    VALUES (?, ?, ?, ?, 0, ?)
                    """
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                try stmt.bind(text: proj, at: 2)
                try stmt.bind(text: "raw", at: 3)
                try stmt.bind(text: cleaned, at: 4)
                try stmt.bind(int64: ts, at: 5)
                _ = try stmt.step()
            }
        }
    }

    private func insertFiles() async throws {
        let rows: [(String, String, String, Int64)] = [
            ("F1", "P_OPTI", "podcast-interview.m4a", 130),
            ("F2", "P_PERS", "random-recording.wav", 140),
        ]
        for (id, proj, title, ts) in rows {
            try await db.withStatement(
                sql: """
                    INSERT INTO files (id, project_id, title, source_path, engine, status, created_at)
                    VALUES (?, ?, ?, ?, 'parakeet', 'completed', ?)
                    """
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                try stmt.bind(text: proj, at: 2)
                try stmt.bind(text: title, at: 3)
                try stmt.bind(text: "/tmp/\(id)", at: 4)
                try stmt.bind(int64: ts, at: 5)
                _ = try stmt.step()
            }
        }
    }

    private func insertVoiceMemos() async throws {
        let rows: [(String, String, String, Int64)] = [
            ("V1", "P_PERS", "Memo 1", 150),
            ("V2", "P_PERS", "Memo 2", 160),
        ]
        for (id, proj, title, ts) in rows {
            try await db.withStatement(
                sql: """
                    INSERT INTO voice_memos (id, project_id, title, file_path, duration_ms, started_at)
                    VALUES (?, ?, ?, ?, 0, ?)
                    """
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                try stmt.bind(text: proj, at: 2)
                try stmt.bind(text: title, at: 3)
                try stmt.bind(text: "/tmp/\(id)", at: 4)
                try stmt.bind(int64: ts, at: 5)
                _ = try stmt.step()
            }
        }
    }

    private func insertFtsRows() async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp)
                VALUES (?, 'you', 'Pricing discussion with prospect', 0)
                """
        ) { stmt in
            try stmt.bind(text: "M1", at: 1)
            _ = try stmt.step()
        }
        try await db.withStatement(
            sql: """
                INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp)
                VALUES (?, 'you', 'We talked about onboarding', 0)
                """
        ) { stmt in
            try stmt.bind(text: "M2", at: 1)
            _ = try stmt.step()
        }
    }
}
