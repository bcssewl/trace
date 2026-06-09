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
        // Full schema: deleteMeeting now also purges vector-index + reconcile
        // state tables, which live beyond SchemaV1.
        try await AppSchema.bootstrap(database: db)

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

    // MARK: deleteMeeting cleanup

    func testDeleteMeetingPurgesFtsVectorAndStateRows() async throws {
        let sessionId = "session_del1"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: sessionId)
        let meta = SessionMetadata(
            sessionId: sessionId, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")
        try await repo.appendUtteranceImmediate(
            Utterance(t: 0, speaker: .you, text: "purge me", conf: 0.9), in: sessionId)
        try await repo.writeNotes("notes to purge", sessionId: sessionId)
        // Vector-index + state rows, as the meeting indexer would have written.
        try await db.exec(
            sql: """
                INSERT INTO kb_chunks (id, source_file, breadcrumb, text, source_sha256, created_at, source_kind, meeting_id)
                VALUES ('DEL_C1', 'meeting/\(sessionId)/transcript', '', 'purge me', 'sha', 0, 'transcript', '\(sessionId)')
                """)
        try await db.exec(
            sql: "INSERT INTO kb_embeddings (chunk_id, vector, config_fingerprint, dim) VALUES ('DEL_C1', x'00000000', 'fp', 1)"
        )
        try await db.exec(
            sql: "INSERT INTO meeting_index_state (meeting_id, last_indexed_at) VALUES ('\(sessionId)', 1)")
        try await repo.finalizeSession(sessionId: sessionId)

        try await repo.deleteMeeting(sessionId: sessionId)

        for (table, column) in [
            ("meetings", "id"), ("transcript_fts", "meeting_id"), ("notes_fts", "meeting_id"),
            ("kb_chunks", "meeting_id"), ("meeting_index_state", "meeting_id"),
            ("fts_reconcile_state", "meeting_id"),
        ] {
            let count = try await db.scalarInt(
                sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = '\(sessionId)'")
            XCTAssertEqual(count, 0, "\(table) must hold no rows for a deleted meeting")
        }
        let orphanEmbeddings = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM kb_embeddings WHERE chunk_id = 'DEL_C1'")
        XCTAssertEqual(orphanEmbeddings, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.sessionDirectory.path))
    }

    // MARK: Keyset pagination

    private func seedMeetings(_ count: Int, projectId: String? = nil) async throws {
        for i in 0..<count {
            let id = String(format: "session_page_%03d", i)
            let layout = try markdown.layout(projectFolderName: "Acme", sessionId: id)
            let meta = SessionMetadata(
                sessionId: id,
                projectId: projectId,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i * 60)),
                sessionDirPath: layout.sessionDirectory.path
            )
            try await repo.createSession(meta, projectFolderName: "Acme")
        }
    }

    func testListMeetingsPagePagesThroughEverythingWithoutOverlap() async throws {
        try await seedMeetings(5)

        var collected: [String] = []
        var cursor: SessionRepository.MeetingPageCursor?
        var pages = 0
        repeat {
            let page = try await repo.listMeetingsPage(after: cursor, limit: 2)
            collected += page.items.map(\.sessionId)
            cursor = page.nextCursor
            pages += 1
            XCTAssertLessThanOrEqual(page.items.count, 2)
        } while cursor != nil && pages < 10

        XCTAssertEqual(pages, 3, "5 rows at page size 2 → 2 + 2 + 1")
        XCTAssertEqual(collected.count, 5)
        XCTAssertEqual(Set(collected).count, 5, "no row may appear in two pages")
        // Most-recent first across the whole sequence.
        XCTAssertEqual(collected, collected.sorted(by: >))
    }

    func testListMeetingsPageBreaksStartedAtTiesByIdWithoutLossOrOverlap() async throws {
        // Same started_at for every row — the cursor must fall back to id.
        for i in 0..<4 {
            let id = "session_tie_\(i)"
            let layout = try markdown.layout(projectFolderName: "Acme", sessionId: id)
            let meta = SessionMetadata(
                sessionId: id,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sessionDirPath: layout.sessionDirectory.path
            )
            try await repo.createSession(meta, projectFolderName: "Acme")
        }
        var collected: [String] = []
        var cursor: SessionRepository.MeetingPageCursor?
        repeat {
            let page = try await repo.listMeetingsPage(after: cursor, limit: 3)
            collected += page.items.map(\.sessionId)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(Set(collected).count, 4)
    }

    func testListMeetingsPageInboxOnlyFiltersUncategorised() async throws {
        // Two uncategorised + (manually) one categorised meeting.
        try await seedMeetings(2)
        let id = "session_filed"
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: id)
        let meta = SessionMetadata(
            sessionId: id, startedAt: Date(), sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")
        try await db.exec(
            sql: """
                INSERT INTO projects (id, name, indicator_color, created_at, updated_at)
                VALUES ('P1', 'Acme', '#000', 0, 0)
                """)
        try await repo.assignProject(sessionId: id, projectId: "P1", manualOverride: true)

        let page = try await repo.listMeetingsPage(inboxOnly: true, limit: 10)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertFalse(page.items.contains { $0.sessionId == id })
        XCTAssertNil(page.nextCursor)
    }
}
