import XCTest

@testable import SharedCore

final class SessionRepositoryTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var markdown: MarkdownStore!
    var repo: SessionRepository!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        let mdRoot = tempDir.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: mdRoot, withIntermediateDirectories: true)
        let config = MarkdownFolderConfig(displayPath: mdRoot.path)
        markdown = MarkdownStore(folderConfig: config)
        repo = SessionRepository(database: db, markdown: markdown, enrichmentDelay: .milliseconds(120))
    }

    override func tearDown() async throws {
        try await db?.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateSessionPersistsMeetingAndWritesJson() async throws {
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: "session_test1")
        let meta = SessionMetadata(
            sessionId: "session_test1",
            projectId: nil,
            title: "Demo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionDirPath: layout.sessionDirectory.path
        )
        try await repo.createSession(meta, projectFolderName: "Acme")

        let count = try await db.scalarInt(sql: "SELECT COUNT(*) FROM meetings WHERE id='session_test1'")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.sessionJsonURL.path))
    }

    func testAppendUtteranceImmediateWritesJsonlAndFts() async throws {
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: "session_test2")
        let meta = SessionMetadata(
            sessionId: "session_test2", startedAt: Date(),
            sessionDirPath: layout.sessionDirectory.path
        )
        try await repo.createSession(meta, projectFolderName: "Acme")

        let u = Utterance(t: 0.0, speaker: .you, text: "find the budget figures", conf: 0.99, asr: "parakeet-eou")
        try await repo.appendUtteranceImmediate(u, in: "session_test2")
        try await repo.finalizeSession(sessionId: "session_test2")

        let restored = try JsonlReader.readAll(Utterance.self, from: layout.transcriptLiveURL)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.text, "find the budget figures")

        let fts = FtsIndex(database: db)
        let hits = try await fts.searchTranscript(query: "budget")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.meetingId, "session_test2")
    }

    func testDeferredUtteranceFlushesAfterEnrichmentWindow() async throws {
        let sessionId = "session_test3"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: sessionId)
        let meta = SessionMetadata(
            sessionId: sessionId, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")

        let u = Utterance(
            t: 1.5, speaker: .other(id: "remote_1"), text: "what about our Q4 numbers", conf: 0.95, diar: "lseend")
        _ = await repo.appendUtteranceDeferred(u, in: sessionId)

        let pendingBefore = await repo.pendingCount()
        XCTAssertEqual(pendingBefore, 1)

        try await Task.sleep(for: .milliseconds(300))

        let pendingAfter = await repo.pendingCount()
        XCTAssertEqual(pendingAfter, 0)

        let restored = try JsonlReader.readAll(Utterance.self, from: layout.transcriptLiveURL)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.text, "what about our Q4 numbers")
    }

    func testAttachEnrichmentMergesIntoJsonl() async throws {
        let sessionId = "session_test4"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: sessionId)
        let meta = SessionMetadata(
            sessionId: sessionId, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")

        let u = Utterance(t: 2.0, speaker: .other(id: "remote_1"), text: "pricing question", conf: 0.93)
        let key = await repo.appendUtteranceDeferred(u, in: sessionId)
        await repo.attachEnrichment(
            key: key, fields: ["coach_suggestion": "show-pricing-card", "kb_hit": "pricing.md#enterprise"])

        try await repo.flushPendingNow(key: key)

        let raw = try String(contentsOf: layout.transcriptLiveURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("coach_suggestion"))
        XCTAssertTrue(raw.contains("show-pricing-card"))
        XCTAssertTrue(raw.contains("kb_hit"))
    }

    func testFinalizeUpdatesEndedAtInSqliteAndJson() async throws {
        let sessionId = "session_test5"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: sessionId)
        let meta = SessionMetadata(
            sessionId: sessionId, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")

        let endedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await repo.finalizeSession(sessionId: sessionId, endedAt: endedAt)

        let endedAtInDb = try await db.withStatement(
            sql: "SELECT ended_at FROM meetings WHERE id=?"
        ) { stmt -> Int64? in
            try stmt.bind(text: sessionId, at: 1)
            _ = try stmt.step()
            return stmt.columnOptionalInt64(at: 0)
        }
        XCTAssertEqual(endedAtInDb, Int64(endedAt.timeIntervalSince1970))

        let restoredMeta = try markdown.readSessionJson(at: layout)
        let restoredEndedAt = try XCTUnwrap(restoredMeta.endedAt)
        XCTAssertEqual(restoredEndedAt.timeIntervalSince1970, endedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testWriteNotesUpdatesFsAndFts() async throws {
        let sessionId = "session_test6"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: sessionId)
        let meta = SessionMetadata(
            sessionId: sessionId, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")

        try await repo.writeNotes("# Action Items\n- ship the dictation wedge", sessionId: sessionId)

        let onDisk = try String(contentsOf: layout.notesURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("ship the dictation wedge"))

        let fts = FtsIndex(database: db)
        let hits = try await fts.searchNotes(query: "dictation")
        XCTAssertEqual(hits.count, 1)
    }
}
