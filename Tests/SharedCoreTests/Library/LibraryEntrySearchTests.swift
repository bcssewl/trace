import XCTest

// Pin bare `LibraryItem` to SharedCore's type — the name otherwise collides with
// an SDK type pulled in transitively under `import XCTest`, which makes an
// unqualified `LibraryItem.Source` annotation ambiguous. (Production code never
// hits this: in-module lookup resolves it unambiguously.)
import struct SharedCore.LibraryItem

@testable import SharedCore

/// BAS-26: `LibraryStore.searchKeyword` must also surface dictations, transcribed
/// files, and voice memos (via the `entry_fts` index), gated by
/// `LibrarySearchScope.sources`.
///
/// Entry sources are only searched when *explicitly*
/// requested, so cross-meeting Q&A (which passes an empty source set → meetings
/// only) is unaffected.
final class LibraryEntrySearchTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var store: LibraryStore!
    let cfg = EmbeddingConfig(
        provider: "ollama", baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text", normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("entrysearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("entry.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        try await SchemaV21.bootstrap(database: db)
        let search = VectorSearch(cache: KbCache(db: db), config: cfg)
        store = LibraryStore(db: db, vectorSearch: search)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func seedEntry(
        _ itemId: String, _ source: LibraryItem.Source, project: String?,
        title: String, startedAt: Int64, text: String
    ) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO entry_fts (item_id, source, project_id, title, started_at, sig, text)
                VALUES (?, ?, ?, ?, ?, 'sig', ?)
                """
        ) { stmt in
            try stmt.bind(text: itemId, at: 1)
            try stmt.bind(text: source.rawValue, at: 2)
            try stmt.bind(optionalText: project, at: 3)
            try stmt.bind(text: title, at: 4)
            try stmt.bind(int64: startedAt, at: 5)
            try stmt.bind(text: text, at: 6)
            _ = try stmt.step()
        }
    }

    func testDictationHitWhenSourceRequested() async throws {
        try await seedEntry(
            "D1", .dictation, project: nil, title: "Quick note", startedAt: 100, text: "remember to buy milk and eggs")
        let hits = try await store.searchKeyword(query: "milk", scope: LibrarySearchScope(sources: [.dictation]))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.source, .dictation)
        XCTAssertEqual(hits.first?.itemId, "D1")
        XCTAssertTrue(hits.first?.snippet.lowercased().contains("milk") ?? false)
    }

    func testFileHitWhenSourceRequested() async throws {
        try await seedEntry(
            "F1", .file, project: nil, title: "interview.m4a", startedAt: 100, text: "we reviewed the quarterly budget")
        let hits = try await store.searchKeyword(query: "budget", scope: LibrarySearchScope(sources: [.file]))
        XCTAssertEqual(hits.map(\.source), [.file])
        XCTAssertEqual(hits.first?.itemId, "F1")
    }

    func testVoiceMemoHitWhenSourceRequested() async throws {
        try await seedEntry(
            "V1", .voiceMemo, project: nil, title: "Memo", startedAt: 100, text: "idea for the onboarding flow")
        let hits = try await store.searchKeyword(query: "onboarding", scope: LibrarySearchScope(sources: [.voiceMemo]))
        XCTAssertEqual(hits.map(\.source), [.voiceMemo])
    }

    func testEmptySourcesExcludesEntries() async throws {
        // Q&A passes an empty source set — entries must NOT leak in (only meetings).
        try await seedEntry("D1", .dictation, project: nil, title: "Note", startedAt: 100, text: "buy milk")
        let hits = try await store.searchKeyword(query: "milk", scope: LibrarySearchScope())
        XCTAssertTrue(hits.isEmpty)
    }

    func testSourceChipIsolation() async throws {
        try await seedEntry("D1", .dictation, project: nil, title: "Note", startedAt: 100, text: "the budget is tight")
        try await seedEntry("F1", .file, project: nil, title: "rec.wav", startedAt: 100, text: "the budget review")
        let dictationOnly = try await store.searchKeyword(
            query: "budget", scope: LibrarySearchScope(sources: [.dictation]))
        XCTAssertEqual(dictationOnly.map(\.source), [.dictation])
        let fileOnly = try await store.searchKeyword(query: "budget", scope: LibrarySearchScope(sources: [.file]))
        XCTAssertEqual(fileOnly.map(\.source), [.file])
    }

    func testProjectScopeFiltersEntries() async throws {
        try await seedEntry("D1", .dictation, project: "P1", title: "Note", startedAt: 100, text: "budget plan")
        try await seedEntry("D2", .dictation, project: "P2", title: "Note", startedAt: 100, text: "budget plan")
        let scoped = try await store.searchKeyword(
            query: "budget", scope: LibrarySearchScope(projectIds: ["P1"], sources: [.dictation])
        )
        XCTAssertEqual(scoped.map(\.itemId), ["D1"])
    }
}
