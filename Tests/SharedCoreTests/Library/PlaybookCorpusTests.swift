import XCTest

@testable import SharedCore

/// BAS-18: the playbook knowledge base is a *global reference corpus* that must
/// co-exist with meeting chunks in the shared `kb_chunks` store. Two invariants:
///  1. (Re)indexing playbooks never touches meeting-derived chunks — the prune is
///     scoped to playbook rows only.
///  2. Multiple playbook folders index into one corpus without clobbering each
///     other (a single unioned prune across all folders).
final class PlaybookCorpusTests: XCTestCase {
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
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbcorpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("c.sqlite"))
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

    @discardableResult
    private func upsert(
        _ sourceFile: String, sha: String, kind: KbChunk.SourceKind, meetingId: String?
    ) async throws -> String {
        let chunk = KbChunk(
            sourceFile: sourceFile, breadcrumb: "", text: "t", sourceSha256: sha,
            sourceKind: kind, meetingId: meetingId
        )
        try await cache.upsert(
            chunk: chunk,
            embedding: KbEmbedding(chunkId: chunk.id, vector: [1, 0, 0], configFingerprint: cfg.fingerprint),
            config: cfg
        )
        return chunk.id
    }

    /// Pruning the playbook corpus to empty (every folder removed/emptied) must
    /// leave meeting transcript/notes/summary chunks intact.
    func testPruningPlaybooksKeepsMeetingChunks() async throws {
        try await upsert("meeting/m1/transcript", sha: "s1", kind: .transcript, meetingId: "m1")
        try await upsert("play/old.md", sha: "s2", kind: .playbook, meetingId: nil)

        try await cache.pruneObsolete(keeping: [])

        let loaded = try await cache.loadValid(config: cfg)
        XCTAssertEqual(loaded.count, 1, "playbook prune must not delete meeting chunks")
        XCTAssertEqual(loaded.first?.0.sourceKind, .transcript)
    }

    /// A non-empty keep set prunes only the *playbook* rows not kept, never the
    /// meeting rows (which aren't in the keep set by construction).
    func testPruningPlaybooksWithKeepSetKeepsMeetingChunks() async throws {
        try await upsert("meeting/m1/transcript", sha: "s1", kind: .transcript, meetingId: "m1")
        try await upsert("play/keep.md", sha: "k", kind: .playbook, meetingId: nil)
        try await upsert("play/drop.md", sha: "d", kind: .playbook, meetingId: nil)

        try await cache.pruneObsolete(keeping: [(file: "play/keep.md", sha: "k")])

        let loaded = try await cache.loadValid(config: cfg)
        let files = Set(loaded.map(\.0.sourceFile))
        XCTAssertTrue(files.contains("meeting/m1/transcript"), "meeting chunk survives")
        XCTAssertTrue(files.contains("play/keep.md"), "kept playbook survives")
        XCTAssertFalse(files.contains("play/drop.md"), "obsolete playbook pruned")
    }

    // MARK: - Multi-folder indexing (one corpus, one unioned prune)

    private static let prose =
        "This is enough plain prose for the markdown chunker to emit a real chunk "
        + "with several words of body text to embed and persist for the test."

    private func makeFolder(_ name: String, file: String, body: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeIndexer() async -> KnowledgeBaseIndexer {
        let router = ModelRouter()
        await router.register(provider: FixedVectorEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg)
        return KnowledgeBaseIndexer(cache: cache, embedder: embedder, config: cfg)
    }

    func testIndexFoldersCoexistInOneCorpus() async throws {
        let a = try makeFolder("fa", file: "alpha.md", body: "# Alpha\n\n\(Self.prose)")
        let b = try makeFolder("fb", file: "beta.md", body: "# Beta\n\n\(Self.prose)")
        let indexer = await makeIndexer()

        let report = try await indexer.index(folders: [a, b])
        XCTAssertGreaterThan(report.indexed, 0)

        let files = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(files.contains("alpha.md"), "folder A chunk present")
        XCTAssertTrue(files.contains("beta.md"), "folder B chunk present — second folder did not clobber the first")
    }

    func testIndexFoldersDoesNotWipeMeetingChunks() async throws {
        try await upsert("meeting/m1/transcript", sha: "s1", kind: .transcript, meetingId: "m1")
        let folder = try makeFolder("fc", file: "p.md", body: "# P\n\n\(Self.prose)")
        let indexer = await makeIndexer()

        _ = try await indexer.index(folders: [folder])

        let files = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(files.contains("meeting/m1/transcript"), "meeting chunk survives playbook indexing")
        XCTAssertTrue(files.contains("p.md"), "playbook chunk indexed")
    }

    func testTransientlyUnreadableFileKeepsItsChunks() async throws {
        let dir = try makeFolder("fu", file: "keep.md", body: "# Keep\n\n\(Self.prose)")
        let indexer = await makeIndexer()
        _ = try await indexer.index(folders: [dir])
        let before = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(before.contains("keep.md"))

        // Simulate a sync lock / permission blip: make the file unreadable.
        let fileURL = dir.appendingPathComponent("keep.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        guard (try? Data(contentsOf: fileURL)) == nil else {
            throw XCTSkip("cannot make the file unreadable here (running as root?)")
        }

        _ = try await indexer.index(folders: [dir])
        let after = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(after.contains("keep.md"), "a transiently-unreadable file's chunks must be preserved, not pruned")
    }

    func testShasForFileReturnsIndexedHashes() async throws {
        try await upsert("play/pricing.md", sha: "sha-abc", kind: .playbook, meetingId: nil)
        try await upsert("meeting/m1/transcript", sha: "sha-xyz", kind: .transcript, meetingId: "m1")

        let shas = try await cache.shasForFile("play/pricing.md")
        XCTAssertEqual(shas, ["sha-abc"])
        // Scoped to playbook rows; an unrelated meeting file returns nothing.
        let none = try await cache.shasForFile("meeting/m1/transcript")
        XCTAssertTrue(none.isEmpty)
    }

    func testReindexPrunesRemovedPlaybookFile() async throws {
        let dir = try makeFolder("fd", file: "keep.md", body: "# Keep\n\n\(Self.prose)")
        try "# Drop\n\n\(Self.prose)".write(
            to: dir.appendingPathComponent("drop.md"), atomically: true, encoding: .utf8
        )
        let indexer = await makeIndexer()
        _ = try await indexer.index(folders: [dir])
        let afterFirst = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(afterFirst.contains("drop.md"))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("drop.md"))
        _ = try await indexer.index(folders: [dir])

        let files = Set(try await cache.loadValid(config: cfg).map(\.0.sourceFile))
        XCTAssertTrue(files.contains("keep.md"), "remaining file kept")
        XCTAssertFalse(files.contains("drop.md"), "removed file pruned on reindex")
    }
}

/// Deterministic, network-free embedding provider for indexing tests — a fixed
/// 3-dim vector per text is enough to drive chunk persistence + counting.
private actor FixedVectorEmbeddingProvider: EmbeddingProvider {
    nonisolated let embeddingKind: EmbeddingProviderKind = .ollama
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        texts.map { _ in [Float(1), 0, 0] }
    }
}
