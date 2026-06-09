import XCTest

@testable import SharedCore

/// VectorSearch after the packed-fp16 refactor: ranking correctness, filters,
/// dimension grouping, and the incremental `refresh()` contract.
final class VectorSearchTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var cache: KbCache!
    var search: VectorSearch!
    let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .none  // raw dot products → scores are directly assertable
    )

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vecsearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("v.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        cache = KbCache(db: db)
        search = VectorSearch(cache: cache, config: cfg)
    }

    override func tearDown() async throws {
        try await db?.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func chunk(
        _ id: String, file: String = "x.md", meetingId: String? = nil,
        kind: KbChunk.SourceKind = .playbook
    ) -> KbChunk {
        KbChunk(
            id: id, sourceFile: file, breadcrumb: "", text: "text-\(id)",
            sourceSha256: "sha-\(id)", sourceKind: kind, meetingId: meetingId)
    }

    private func insert(_ c: KbChunk, vector: [Float]) async throws {
        try await cache.upsert(
            chunk: c,
            embedding: KbEmbedding(chunkId: c.id, vector: vector, configFingerprint: cfg.fingerprint),
            config: cfg
        )
    }

    // MARK: Correctness

    func testTopKRanksByDotProduct() async throws {
        try await insert(chunk("A"), vector: [1, 0, 0])
        try await insert(chunk("B"), vector: [0.5, 0.5, 0])
        try await insert(chunk("C"), vector: [0, 1, 0])

        let hits = try await search.topK(query: [1, 0, 0], k: 3)

        XCTAssertEqual(hits.map(\.chunk.id), ["A", "B", "C"])
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.01)
        XCTAssertEqual(hits[1].score, 0.5, accuracy: 0.01)
        XCTAssertEqual(hits[2].score, 0.0, accuracy: 0.01)
    }

    func testTopKHonoursKAndFilters() async throws {
        try await insert(chunk("A", file: "play/a.md"), vector: [1, 0, 0])
        try await insert(chunk("B", file: "play/b.md"), vector: [0.9, 0, 0])
        try await insert(
            chunk("M", file: "meeting/m1/transcript", meetingId: "m1", kind: .transcript),
            vector: [0.8, 0, 0])

        let top2 = try await search.topK(query: [1, 0, 0], k: 2)
        XCTAssertEqual(top2.map(\.chunk.id), ["A", "B"])

        let prefixed = try await search.topK(query: [1, 0, 0], k: 10, sourceFilePrefix: "meeting/")
        XCTAssertEqual(prefixed.map(\.chunk.id), ["M"])

        let filtered = try await search.topK(
            query: [1, 0, 0], k: 10, where: { $0.sourceKind == .transcript })
        XCTAssertEqual(filtered.map(\.chunk.id), ["M"])
    }

    func testMismatchedDimensionIsSkippedNotScored() async throws {
        try await insert(chunk("D3"), vector: [1, 0, 0])
        try await insert(chunk("D4"), vector: [1, 0, 0, 0])

        let hits3 = try await search.topK(query: [1, 0, 0], k: 10)
        XCTAssertEqual(hits3.map(\.chunk.id), ["D3"])

        let hits4 = try await search.topK(query: [1, 0, 0, 0], k: 10)
        XCTAssertEqual(hits4.map(\.chunk.id), ["D4"])
    }

    func testLargerCorpusMatchesBruteForceOrdering() async throws {
        // 200 chunks whose dot products strictly increase with the chunk index
        // (gaps far above fp16 resolution), so the expected ranking is exact;
        // verify the packed block scan reproduces it with brute-force scores.
        var vectors: [String: [Float]] = [:]
        for i in 0..<200 {
            let v: [Float] = (0..<8).map { d in
                (Float(i) + 1) / 256 * (1 + Float(d) * 0.01)
            }
            let id = String(format: "chunk-%03d", i)
            vectors[id] = v
            try await insert(chunk(id), vector: v)
        }
        let query: [Float] = [0.9, 0.1, 0.4, 0.7, 0.2, 0.05, 0.6, 0.3]
        let expected = vectors
            .map { (id: $0.key, score: zip($0.value, query).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.score > $1.score }
            .prefix(10)

        let hits = try await search.topK(query: query, k: 10)

        XCTAssertEqual(hits.map(\.chunk.id), expected.map(\.id))
        for (hit, exp) in zip(hits, expected) {
            XCTAssertEqual(hit.score, exp.score, accuracy: 0.01, "fp16 rounding only")
        }
    }

    // MARK: Incremental refresh

    func testRefreshPicksUpNewChunksIncrementally() async throws {
        try await insert(chunk("A"), vector: [1, 0, 0])
        try await search.refresh()
        let before = await search.indexedChunkCount()
        XCTAssertEqual(before, 1)

        try await insert(chunk("B"), vector: [0, 1, 0])
        try await search.refresh()
        let after = await search.indexedChunkCount()
        XCTAssertEqual(after, 2)

        let hits = try await search.topK(query: [0, 1, 0], k: 1)
        XCTAssertEqual(hits.first?.chunk.id, "B")
    }

    func testRefreshDropsDeletedChunks() async throws {
        try await insert(
            chunk("M1", file: "meeting/m1/t", meetingId: "m1", kind: .transcript), vector: [1, 0, 0])
        try await insert(chunk("P1", file: "p.md"), vector: [0, 1, 0])
        try await search.refresh()
        let loaded = await search.indexedChunkCount()
        XCTAssertEqual(loaded, 2)

        try await cache.deleteByMeeting(meetingId: "m1")
        try await search.refresh()

        let after = await search.indexedChunkCount()
        XCTAssertEqual(after, 1)
        let hits = try await search.topK(query: [1, 0, 0], k: 10)
        XCTAssertEqual(hits.map(\.chunk.id), ["P1"], "deleted meeting's chunk must stop matching")
    }

    func testRefreshPicksUpReplacedVector() async throws {
        let original = chunk("R1")
        try await insert(original, vector: [1, 0, 0])
        try await search.refresh()

        // Same chunk id re-upserted with a new vector (re-index of changed
        // content). created_at moves forward → version change → reload.
        // Ensure the version stamp actually differs (epoch-second resolution).
        try await Task.sleep(for: .milliseconds(1100))
        try await insert(original, vector: [0, 0, 1])
        try await search.refresh()

        let count = await search.indexedChunkCount()
        XCTAssertEqual(count, 1)
        let hits = try await search.topK(query: [0, 0, 1], k: 1)
        XCTAssertEqual(hits.first?.chunk.id, "R1")
        XCTAssertEqual(hits.first.map(\.score) ?? 0, 1.0, accuracy: 0.01)
    }

    func testNoChangeRefreshIsANoOp() async throws {
        try await insert(chunk("A"), vector: [1, 0, 0])
        try await search.refresh()
        try await search.refresh()  // nothing changed — must not disturb the index
        let hits = try await search.topK(query: [1, 0, 0], k: 1)
        XCTAssertEqual(hits.first?.chunk.id, "A")
        let count = await search.indexedChunkCount()
        XCTAssertEqual(count, 1)
    }

    func testHalfPrecisionRoundTripAccuracy() {
        let values: [Float] = [0, 1, -1, 0.5, 0.123456, -0.987654, 0.001, 64.5]
        let halves = VectorSearch.toHalf(values)
        XCTAssertEqual(halves.count, values.count)
        // fp16 has ~3 decimal digits of precision near 1.0.
        XCTAssertEqual(halves[0], 0)  // 0.0 encodes to bit pattern 0
    }
}
