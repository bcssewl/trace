import XCTest

@testable import SharedCore

final class PlaybookStoreTests: XCTestCase {

    private var tempDir: URL!
    private var db: SqliteDatabase!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("playbookstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("pb.sqlite"))
        try await SchemaV1.bootstrap(database: db)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: helpers

    /// A bookmark factory that does NOT require the app sandbox: it stores the
    /// URL's path bytes as the "bookmark" blob so persistence round-trips can be
    /// verified deterministically in unit tests.
    ///
    /// Real security-scoped bookmark
    /// creation/resolution is covered separately in
    /// `testRealSecurityScopedBookmarkRoundTrips`.
    private func stubFactory() -> @Sendable (URL) throws -> SecurityScopedBookmark {
        { url in
            SecurityScopedBookmark(
                bookmarkData: Data(url.path.utf8),
                originalPath: url.path
            )
        }
    }

    private func makeStore(real: Bool = false) -> PlaybookStore {
        if real {
            return PlaybookStore(database: db)
        }
        return PlaybookStore(database: db, bookmarkFactory: stubFactory())
    }

    private func makeProject(_ id: UUID, name: String) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO projects (id, name, indicator_color, coach_config, created_at, updated_at)
                VALUES (?, ?, '#000', '{}', 0, 0)
                """
        ) { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            try stmt.bind(text: name, at: 2)
            _ = try stmt.step()
        }
    }

    private func tempFolder(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: schema

    func testEnsureSchemaAddsFolderColumns() async throws {
        let store = makeStore()
        try await store.ensureSchema()

        var columns: Set<String> = []
        try await db.withStatement(sql: "PRAGMA table_info(playbooks)") { stmt in
            while try stmt.step() == .row {
                if let name = stmt.columnText(at: 1) { columns.insert(name) }
            }
        }
        XCTAssertTrue(
            columns.isSuperset(of: ["bookmark_data", "created_at"]),
            "missing columns: \(Set(["bookmark_data", "created_at"]).subtracting(columns))")
    }

    func testSchemaV18MigrationMetadata() {
        XCTAssertEqual(SchemaV18.version, 18)
        XCTAssertEqual(SchemaV18.migration.version, 18)
        XCTAssertEqual(SchemaV18.migration.name, "add_playbook_folder_columns")
    }

    func testEnsureSchemaIsIdempotent() async throws {
        let store = makeStore()
        try await store.ensureSchema()
        try await store.ensureSchema()
        try await SchemaV18.bootstrap(database: db)  // also via the formal path
        let version = try await db.scalarInt(sql: "SELECT MAX(version) FROM _migrations")
        XCTAssertEqual(version, 18)
    }

    // MARK: add -> list round trip

    func testAddThenListRoundTrip() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()
        let folderURL = try tempFolder("docs")

        let added = try await store.addFolder(projectId: project, url: folderURL)
        XCTAssertEqual(added.projectId, project)
        XCTAssertEqual(added.path, folderURL.standardizedFileURL.path)
        XCTAssertNil(added.indexedAt)
        XCTAssertFalse(added.isStale)

        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, added.id)
        XCTAssertEqual(listed[0].path, folderURL.standardizedFileURL.path)
        XCTAssertEqual(listed[0].projectId, project)
    }

    func testListOrdersByCreatedAtAscending() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()

        let a = try await store.addFolder(projectId: project, url: try tempFolder("a"))
        let b = try await store.addFolder(projectId: project, url: try tempFolder("b"))

        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.map(\.id), [a.id, b.id])
    }

    // MARK: remove

    func testRemoveFolder() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()
        let added = try await store.addFolder(projectId: project, url: try tempFolder("docs"))

        try await store.removeFolder(id: added.id)
        let listed = try await store.folders(projectId: project)
        XCTAssertTrue(listed.isEmpty)
    }

    func testRemoveIsScopedToId() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()
        let keep = try await store.addFolder(projectId: project, url: try tempFolder("keep"))
        let drop = try await store.addFolder(projectId: project, url: try tempFolder("drop"))

        try await store.removeFolder(id: drop.id)
        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.map(\.id), [keep.id])
    }

    // MARK: per-project isolation

    func testPerProjectIsolation() async throws {
        let projectA = UUID()
        let projectB = UUID()
        try await makeProject(projectA, name: "Alpha")
        try await makeProject(projectB, name: "Beta")
        let store = makeStore()

        let a1 = try await store.addFolder(projectId: projectA, url: try tempFolder("a1"))
        let a2 = try await store.addFolder(projectId: projectA, url: try tempFolder("a2"))
        let b1 = try await store.addFolder(projectId: projectB, url: try tempFolder("b1"))

        let aFolders = try await store.folders(projectId: projectA)
        let bFolders = try await store.folders(projectId: projectB)

        XCTAssertEqual(Set(aFolders.map(\.id)), [a1.id, a2.id])
        XCTAssertEqual(bFolders.map(\.id), [b1.id])
        XCTAssertFalse(Set(aFolders.map(\.id)).contains(b1.id))
    }

    func testRemovingProjectFolderDoesNotAffectOtherProject() async throws {
        let projectA = UUID()
        let projectB = UUID()
        try await makeProject(projectA, name: "Alpha")
        try await makeProject(projectB, name: "Beta")
        let store = makeStore()
        let a1 = try await store.addFolder(projectId: projectA, url: try tempFolder("a1"))
        let b1 = try await store.addFolder(projectId: projectB, url: try tempFolder("b1"))

        try await store.removeFolder(id: a1.id)
        let aFolders = try await store.folders(projectId: projectA)
        let bFolders = try await store.folders(projectId: projectB)
        XCTAssertTrue(aFolders.isEmpty)
        XCTAssertEqual(bFolders.map(\.id), [b1.id])
    }

    // MARK: bookmark resolution

    func testStubBookmarkRoundTripsPath() async throws {
        // With the stub factory, the bookmark blob is the path bytes and does
        // not resolve to a real URL — exercising the "stale/unresolvable" branch
        // of folders(projectId:).
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()
        let folderURL = try tempFolder("docs")
        _ = try await store.addFolder(projectId: project, url: folderURL)

        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.count, 1)
        // Stub blob can't resolve via the security-scope API -> flagged stale.
        XCTAssertTrue(listed[0].isStale)
        XCTAssertNil(listed[0].url)
        // Display path is always retained regardless of resolution.
        XCTAssertEqual(listed[0].path, folderURL.standardizedFileURL.path)
    }

    func testRealSecurityScopedBookmarkRoundTrips() async throws {
        // Uses the real SecurityScopedBookmark.make/resolve against a live temp
        // directory. Creating a security-scoped bookmark for an existing folder
        // succeeds outside a sandbox; if a particular CI host refuses, we skip
        // rather than fail, since the persistence path is already covered above.
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let folderURL = try tempFolder("realdocs")

        let bookmark: SecurityScopedBookmark
        do {
            bookmark = try SecurityScopedBookmark.make(from: folderURL.standardizedFileURL)
        } catch {
            throw XCTSkip("security-scoped bookmark creation unavailable here: \(error)")
        }

        let store = makeStore(real: true)
        let added = try await store.addFolder(projectId: project, url: folderURL)
        XCTAssertNotNil(added.url)

        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].url?.standardizedFileURL.path, folderURL.standardizedFileURL.path)
        XCTAssertFalse(listed[0].isStale)

        let resolved = try await store.resolvedFolder(id: added.id)
        XCTAssertEqual(resolved?.url.standardizedFileURL.path, folderURL.standardizedFileURL.path)

        // Sanity: the bookmark we made independently resolves to the same place.
        let direct = try bookmark.resolve()
        XCTAssertEqual(direct.url.standardizedFileURL.path, folderURL.standardizedFileURL.path)
    }

    func testLocateFileResolvesRelativePathAndNilWhenAbsent() async throws {
        // BAS-27: a playbook citation carries a relative `source_file`; locateFile
        // resolves it to an absolute URL by scanning indexed folders' bookmarks.
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let folderURL = try tempFolder("locatedocs")
        let sub = folderURL.appendingPathComponent("sales", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("pricing.md")
        try Data("# Pricing\nbody".utf8).write(to: file)

        do {
            _ = try SecurityScopedBookmark.make(from: folderURL.standardizedFileURL)
        } catch {
            throw XCTSkip("security-scoped bookmark creation unavailable here: \(error)")
        }

        let store = makeStore(real: true)
        _ = try await store.addFolder(projectId: project, url: folderURL)

        let located = try await store.locateFile(relativePath: "sales/pricing.md")
        XCTAssertEqual(located?.standardizedFileURL.path, file.standardizedFileURL.path)

        let missing = try await store.locateFile(relativePath: "does/not/exist.md")
        XCTAssertNil(missing)
    }

    // MARK: indexing

    func testIndexEmptyProjectReturnsZero() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let store = makeStore()
        let indexer = try await makeIndexer()
        let report = try await store.index(projectId: project, into: indexer)
        XCTAssertEqual(report.indexed, 0)
    }

    func testIndexResolvableFolderCountsChunksAndStamps() async throws {
        let project = UUID()
        try await makeProject(project, name: "Sales")
        let folderURL = try tempFolder("indexdocs")
        // A markdown file with enough body to produce at least one chunk.
        let md = """
            # Pricing

            Our standard discount policy allows up to fifteen percent off list
            price with manager sign-off. Anything beyond that requires director
            approval. This sentence exists to give the chunker real prose to
            work with so a chunk is emitted.
            """
        try md.write(
            to: folderURL.appendingPathComponent("pricing.md"),
            atomically: true, encoding: .utf8
        )

        // Real bookmark so index() can resolve it; skip if unavailable.
        do {
            _ = try SecurityScopedBookmark.make(from: folderURL.standardizedFileURL)
        } catch {
            throw XCTSkip("security-scoped bookmark creation unavailable here: \(error)")
        }

        let store = makeStore(real: true)
        let added = try await store.addFolder(projectId: project, url: folderURL)
        let indexer = try await makeIndexer()

        let report = try await store.index(projectId: project, into: indexer)
        XCTAssertGreaterThan(report.indexed, 0)

        let listed = try await store.folders(projectId: project)
        XCTAssertEqual(listed.first?.id, added.id)
        XCTAssertNotNil(listed.first?.indexedAt, "indexed_at should be stamped after indexing")
    }

    /// Builds a `KnowledgeBaseIndexer` wired to a deterministic local embedder
    /// so indexing does not hit the network.
    ///
    /// The embedder returns a fixed
    /// 3-dim vector per text — enough to drive chunk persistence + counting.
    private func makeIndexer() async throws -> KnowledgeBaseIndexer {
        // The shared kb_chunks store now carries v19 provenance columns the
        // indexer writes through; ensure they exist on this test database.
        try await SchemaV19.bootstrap(database: db)
        // The default `.embeddingsIndex` route resolves to provider `.ollama`,
        // so the stub registers itself under that kind.
        let cfg = EmbeddingConfig(
            provider: "ollama",
            baseURL: URL(string: "http://localhost:11434"),
            model: "nomic-embed-text",
            normalization: .unitL2
        )
        let router = ModelRouter()
        await router.register(provider: StubEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg)
        let cache = KbCache(db: db)
        return KnowledgeBaseIndexer(cache: cache, embedder: embedder, config: cfg)
    }
}

/// Deterministic, network-free embedding provider for indexing tests.
private actor StubEmbeddingProvider: EmbeddingProvider {
    nonisolated let embeddingKind: EmbeddingProviderKind = .ollama
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        texts.map { _ in [Float(1), 0, 0] }
    }
}
