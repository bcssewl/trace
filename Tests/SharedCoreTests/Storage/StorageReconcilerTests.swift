import XCTest

@testable import SharedCore

/// Launch-time reconcile pass: FTS ↔ content repair, abandoned-meeting closure,
/// ghost/orphan cleanup, and the cached-signature cheapness contract.
final class StorageReconcilerTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var markdown: MarkdownStore!
    var repo: SessionRepository!
    var reconciler: StorageReconciler!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await AppSchema.bootstrap(database: db)
        let mdRoot = tempDir.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: mdRoot, withIntermediateDirectories: true)
        markdown = MarkdownStore(folderConfig: MarkdownFolderConfig(displayPath: mdRoot.path))
        repo = SessionRepository(database: db, markdown: markdown, enrichmentDelay: .milliseconds(50))
        reconciler = StorageReconciler(database: db)
    }

    override func tearDown() async throws {
        try await db?.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    @discardableResult
    private func makeSession(
        _ id: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        utterances: [Utterance] = [],
        finalize: Bool = true
    ) async throws -> SessionLayout {
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: id)
        let meta = SessionMetadata(
            sessionId: id, startedAt: startedAt, sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")
        for utt in utterances {
            try await repo.appendUtteranceImmediate(utt, in: id)
        }
        if finalize {
            try await repo.finalizeSession(sessionId: id, endedAt: startedAt.addingTimeInterval(600))
        }
        return layout
    }

    private func backdate(_ url: URL, by seconds: TimeInterval = 3600) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    // MARK: FTS repair

    func testRepairsMissingTranscriptFtsRows() async throws {
        try await makeSession(
            "session_r1",
            utterances: [
                Utterance(t: 0, speaker: .you, text: "alpha budget talk", conf: 0.9),
                Utterance(t: 5, speaker: .other(id: "remote_1"), text: "beta pricing talk", conf: 0.9),
            ])
        // Simulate the crash window: content on disk, FTS rows lost.
        try await db.exec(sql: "DELETE FROM transcript_fts WHERE meeting_id = 'session_r1'")

        let report = try await reconciler.reconcile()

        XCTAssertEqual(report.transcriptsReindexed, 1)
        let fts = FtsIndex(database: db)
        let hits = try await fts.searchTranscript(query: "pricing")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.meetingId, "session_r1")
        let count = try await fts.transcriptRowCount(meetingId: "session_r1")
        XCTAssertEqual(count, 2)
    }

    func testRepairsStaleNotesFts() async throws {
        let layout = try await makeSession("session_r2")
        try await repo.writeNotes("# Old\noriginal contents", sessionId: "session_r2")
        // Notes edited on disk without the FTS upsert (crash between the two,
        // or an external editor touched the markdown).
        try "# New\ncompletely different zebra".write(
            to: layout.notesURL, atomically: true, encoding: .utf8)

        let report = try await reconciler.reconcile()

        XCTAssertEqual(report.notesReindexed, 1)
        let fts = FtsIndex(database: db)
        let zebra = try await fts.searchNotes(query: "zebra")
        XCTAssertEqual(zebra.count, 1)
        let stale = try await fts.searchNotes(query: "original")
        XCTAssertEqual(stale.count, 0)
    }

    func testSecondPassSkipsCleanSessionsViaCachedSignatures() async throws {
        try await makeSession(
            "session_r3",
            utterances: [Utterance(t: 0, speaker: .you, text: "hello", conf: 0.9)])
        try await db.exec(sql: "DELETE FROM transcript_fts WHERE meeting_id = 'session_r3'")

        let first = try await reconciler.reconcile()
        XCTAssertEqual(first.transcriptsReindexed, 1)

        let second = try await reconciler.reconcile()
        XCTAssertEqual(second.transcriptsReindexed, 0)
        XCTAssertEqual(second.notesReindexed, 0)
        XCTAssertEqual(second.meetingsClean, 1, "unchanged session must be skipped via the cached signature")
    }

    // MARK: Abandoned meetings

    func testClosesAbandonedMeetingFromLastUtterance() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let layout = try await makeSession(
            "session_r4", startedAt: startedAt,
            utterances: [
                Utterance(t: 1, speaker: .you, text: "start", conf: 0.9),
                Utterance(t: 42, speaker: .you, text: "last words", conf: 0.9),
            ],
            finalize: false)
        // Make the transcript look idle (outside the activity grace window).
        try backdate(layout.transcriptLiveURL)

        let report = try await reconciler.reconcile()

        XCTAssertEqual(report.abandonedMeetingsClosed, 1)
        let endedAt = try await db.withStatement(
            sql: "SELECT ended_at FROM meetings WHERE id = 'session_r4'"
        ) { stmt -> Int64? in
            _ = try stmt.step()
            return stmt.columnOptionalInt64(at: 0)
        }
        XCTAssertEqual(endedAt, Int64(startedAt.timeIntervalSince1970) + 42)
    }

    func testLeavesRecentlyActiveOpenMeetingAlone() async throws {
        try await makeSession(
            "session_r5",
            utterances: [Utterance(t: 3, speaker: .you, text: "still going", conf: 0.9)],
            finalize: false)
        // Transcript mtime is "now" → inside the grace window → treated as live.
        let report = try await reconciler.reconcile()

        XCTAssertEqual(report.abandonedMeetingsClosed, 0)
        let endedAt = try await db.withStatement(
            sql: "SELECT ended_at FROM meetings WHERE id = 'session_r5'"
        ) { stmt -> Int64? in
            _ = try stmt.step()
            return stmt.columnOptionalInt64(at: 0)
        }
        XCTAssertNil(endedAt)
    }

    func testClosesAbandonedMeetingWithNoTranscriptAtStartTime() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let layout = try markdown.layout(projectFolderName: "Acme", sessionId: "session_r6")
        let meta = SessionMetadata(
            sessionId: "session_r6", startedAt: startedAt,
            sessionDirPath: layout.sessionDirectory.path)
        try await repo.createSession(meta, projectFolderName: "Acme")
        // No utterances ever written; the live JSONL doesn't even exist.

        let report = try await reconciler.reconcile()

        XCTAssertEqual(report.abandonedMeetingsClosed, 1)
        let endedAt = try await db.withStatement(
            sql: "SELECT ended_at FROM meetings WHERE id = 'session_r6'"
        ) { stmt -> Int64? in
            _ = try stmt.step()
            return stmt.columnOptionalInt64(at: 0)
        }
        XCTAssertEqual(endedAt, Int64(startedAt.timeIntervalSince1970))
    }

    // MARK: Ghost / orphan cleanup

    func testRemovesGhostEntryFtsAndFtsRowsOfDeletedItems() async throws {
        // entry_fts row for a file that no longer exists in `files`.
        try await db.exec(
            sql: """
                INSERT INTO entry_fts (item_id, source, project_id, title, started_at, sig, text)
                VALUES ('GONE_FILE', 'file', NULL, 'ghost', 0, 'sig', 'ghost text')
                """)
        // transcript/notes FTS rows for a meeting that was deleted pre-fix.
        try await db.exec(
            sql: "INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp) VALUES ('GONE_MTG', 'you', 'ghost', 0)"
        )
        try await db.exec(
            sql: "INSERT INTO notes_fts (meeting_id, text) VALUES ('GONE_MTG', 'ghost notes')")

        let report = try await reconciler.reconcile()

        XCTAssertGreaterThanOrEqual(report.ghostRowsRemoved, 3)
        let entryCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM entry_fts")
        XCTAssertEqual(entryCount, 0)
        let tCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM transcript_fts")
        XCTAssertEqual(tCount, 0)
        let nCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM notes_fts")
        XCTAssertEqual(nCount, 0)
    }

    func testRemovesKbChunksOfDeletedMeetingsAndOrphanEmbeddings() async throws {
        // Chunk belonging to a meeting that no longer exists.
        try await db.exec(
            sql: """
                INSERT INTO kb_chunks (id, source_file, breadcrumb, text, source_sha256, created_at, source_kind, meeting_id)
                VALUES ('C1', 'meeting/GONE/transcript', '', 'ghost', 'sha', 0, 'transcript', 'GONE_MTG')
                """)
        try await db.exec(
            sql: "INSERT INTO kb_embeddings (chunk_id, vector, config_fingerprint, dim) VALUES ('C1', x'00000000', 'fp', 1)"
        )
        // Embedding whose chunk row vanished (the old pruneObsolete crash
        // window). The FK would block creating it directly, so plant it with
        // enforcement briefly off — exactly the state a crashed prune left.
        try await db.exec(sql: "PRAGMA foreign_keys = OFF")
        try await db.exec(
            sql: "INSERT INTO kb_embeddings (chunk_id, vector, config_fingerprint, dim) VALUES ('ORPHAN', x'00000000', 'fp', 1)"
        )
        try await db.exec(sql: "PRAGMA foreign_keys = ON")

        let report = try await reconciler.reconcile()

        XCTAssertGreaterThanOrEqual(report.ghostRowsRemoved, 1)
        // C1's embedding may cascade away with its chunk; ORPHAN is always
        // removed by the orphan sweep.
        XCTAssertGreaterThanOrEqual(report.orphanEmbeddingsRemoved, 1)
        let chunkCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM kb_chunks")
        XCTAssertEqual(chunkCount, 0)
        let embCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM kb_embeddings")
        XCTAssertEqual(embCount, 0)
    }

    func testCleanRunReportsNothingToRepair() async throws {
        try await makeSession(
            "session_r7",
            utterances: [Utterance(t: 0, speaker: .you, text: "tidy", conf: 0.9)])
        _ = try await reconciler.reconcile()
        let report = try await reconciler.reconcile()
        XCTAssertFalse(report.didRepairAnything)
        XCTAssertTrue(report.summary.contains("nothing needed repair"))
    }
}
