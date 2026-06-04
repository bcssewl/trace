import XCTest

@testable import SharedCore

/// BAS-26: `LibraryEntryIndexer` reconciles `entry_fts` from the three
/// whole-item sources — dictations (in-DB text), transcribed files + voice memos
/// (transcript on disk).
///
/// It is change-gated (a content SHA for dictations,
/// `mtime|size` for on-disk transcripts) so unchanged items are skipped without
/// re-reading, prunes rows whose item disappeared, and re-indexes changed ones.
final class LibraryEntryIndexerTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var indexer: LibraryEntryIndexer!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("entryidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV21.bootstrap(database: db)
        indexer = LibraryEntryIndexer(db: db)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: seeding

    private func insertDictation(
        _ id: String, cleaned: String, raw: String = "raw", project: String? = nil, startedAt: Int64 = 100
    ) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO dictations (id, project_id, raw_text, cleaned_text, duration_ms, started_at)
                VALUES (?, ?, ?, ?, 0, ?)
                """
        ) { stmt in
            try stmt.bind(text: id, at: 1)
            try stmt.bind(optionalText: project, at: 2)
            try stmt.bind(text: raw, at: 3)
            try stmt.bind(text: cleaned, at: 4)
            try stmt.bind(int64: startedAt, at: 5)
            _ = try stmt.step()
        }
    }

    private func updateDictation(_ id: String, cleaned: String) async throws {
        try await db.withStatement(sql: "UPDATE dictations SET cleaned_text = ? WHERE id = ?") { stmt in
            try stmt.bind(text: cleaned, at: 1)
            try stmt.bind(text: id, at: 2)
            _ = try stmt.step()
        }
    }

    private func deleteDictation(_ id: String) async throws {
        try await db.withStatement(sql: "DELETE FROM dictations WHERE id = ?") { stmt in
            try stmt.bind(text: id, at: 1)
            _ = try stmt.step()
        }
    }

    /// Seed a completed file row whose transcript lives in a real temp markdown
    /// file, returning that file's URL so the test can mutate it.
    @discardableResult
    private func insertFile(
        _ id: String, transcript: String, title: String = "rec", project: String? = nil
    ) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(id).md")
        try Data(transcript.utf8).write(to: url)
        try await db.withStatement(
            sql: """
                INSERT INTO files (id, project_id, title, source_path, transcript_path, engine, status, created_at)
                VALUES (?, ?, ?, ?, ?, 'parakeet', 'completed', 100)
                """
        ) { stmt in
            try stmt.bind(text: id, at: 1)
            try stmt.bind(optionalText: project, at: 2)
            try stmt.bind(text: title, at: 3)
            try stmt.bind(text: "/tmp/\(id).m4a", at: 4)
            try stmt.bind(text: url.path, at: 5)
            _ = try stmt.step()
        }
        return url
    }

    // MARK: reading entry_fts

    private func entryRow(_ itemId: String) async throws -> (source: String, text: String, sig: String)? {
        try await db.withStatement(sql: "SELECT source, text, sig FROM entry_fts WHERE item_id = ?") { stmt in
            try stmt.bind(text: itemId, at: 1)
            guard try stmt.step() == .row else { return nil }
            return (stmt.columnText(at: 0) ?? "", stmt.columnText(at: 1) ?? "", stmt.columnText(at: 2) ?? "")
        }
    }

    private func entryCount() async throws -> Int {
        try await db.scalarInt(sql: "SELECT COUNT(*) FROM entry_fts")
    }

    // MARK: tests

    func testIndexesDictationText() async throws {
        try await insertDictation("D1", cleaned: "remember to buy milk and eggs")
        let report = try await indexer.reconcile()
        XCTAssertEqual(report.indexed, 1)
        let row = try await entryRow("D1")
        XCTAssertEqual(row?.source, "dictation")
        XCTAssertTrue(row?.text.contains("milk") ?? false)
    }

    func testIndexesFileTranscriptFromDisk() async throws {
        try await insertFile("F1", transcript: "# rec\n\nwe reviewed the quarterly budget")
        let report = try await indexer.reconcile()
        XCTAssertEqual(report.indexed, 1)
        let row = try await entryRow("F1")
        XCTAssertEqual(row?.source, "file")
        XCTAssertTrue(row?.text.contains("budget") ?? false)
    }

    func testUnchangedItemsSkippedOnSecondPass() async throws {
        try await insertDictation("D1", cleaned: "hello world")
        _ = try await indexer.reconcile()
        let second = try await indexer.reconcile()
        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(second.skipped, 1)
        let count = try await entryCount()
        XCTAssertEqual(count, 1)  // not duplicated
    }

    func testChangedDictationReindexed() async throws {
        try await insertDictation("D1", cleaned: "first version")
        _ = try await indexer.reconcile()
        let sig1 = try await entryRow("D1")?.sig
        try await updateDictation("D1", cleaned: "second totally different version")
        let report = try await indexer.reconcile()
        XCTAssertEqual(report.indexed, 1)
        let row = try await entryRow("D1")
        XCTAssertTrue(row?.text.contains("second") ?? false)
        XCTAssertNotEqual(row?.sig, sig1)
        let count = try await entryCount()
        XCTAssertEqual(count, 1)  // replaced, not appended
    }

    func testDeletedItemPruned() async throws {
        try await insertDictation("D1", cleaned: "ephemeral note")
        _ = try await indexer.reconcile()
        try await deleteDictation("D1")
        let report = try await indexer.reconcile()
        XCTAssertEqual(report.pruned, 1)
        let row = try await entryRow("D1")
        XCTAssertNil(row)
    }

    func testEmptyDictationNotIndexed() async throws {
        // Both ASR + cleaned text empty → nothing to index. (A blank cleaned_text
        // with real raw_text correctly falls back to raw and IS indexed.)
        try await insertDictation("D1", cleaned: "   ", raw: "")
        let report = try await indexer.reconcile()
        XCTAssertEqual(report.indexed, 0)
        let row = try await entryRow("D1")
        XCTAssertNil(row)
    }
}
