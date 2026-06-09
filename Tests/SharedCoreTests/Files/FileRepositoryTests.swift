import XCTest

@testable import SharedCore

final class FileRepositoryTests: XCTestCase {

    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var repo: FileRepository!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        // Full schema so the files table carries the v29 kind/origin columns.
        try await AppSchema.bootstrap(database: db)
        repo = FileRepository(database: db)
    }

    override func tearDown() async throws {
        try await db.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleJob(_ name: String = "clip") -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            origin: .dragDrop
        )!
    }

    func testInsertQueuedWritesRowWithExpectedFields() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet:tdt-v3")
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.id, job.id.uuidString)
        XCTAssertEqual(row?.sourcePath, job.sourceURL.path)
        XCTAssertEqual(row?.engine, "parakeet:tdt-v3")
        XCTAssertEqual(row?.status, .queued)
        XCTAssertNil(row?.transcriptPath)
        XCTAssertNil(row?.completedAt)
    }

    func testInsertQueuedIsIdempotentOnPrimaryKey() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet")
        try await repo.updateStatus(id: job.id, status: .transcribing)
        try await repo.insertQueued(job: job, engine: "parakeet-v2")
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .queued, "Re-insert resets back to queued")
        XCTAssertEqual(row?.engine, "parakeet-v2", "Re-insert applies the new engine")
        XCTAssertNil(row?.errorReason)
    }

    func testUpdateStatusFlowsThroughStages() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet")

        for stage in [
            FileBatchStatus.extracting, .transcribing, .summarizing, .writing,
        ] {
            try await repo.updateStatus(id: job.id, status: stage)
            let row = try await repo.fetch(id: job.id)
            XCTAssertEqual(row?.status, stage)
        }
    }

    func testMarkCompletedSetsTranscriptPathAndDuration() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet")
        try await repo.markCompleted(
            id: job.id, transcriptPath: "/notes/abc.md", durationMs: 12_345
        )
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(row?.transcriptPath, "/notes/abc.md")
        XCTAssertEqual(row?.durationMs, 12_345)
        XCTAssertNotNil(row?.completedAt)
        XCTAssertNil(row?.errorReason)
    }

    func testMarkFailedCarriesStageAndReason() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet")
        let failure = FileBatchFailure(stage: .transcribing, reason: "model timed out")
        try await repo.markFailed(id: job.id, failure: failure)
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .failed)
        XCTAssertTrue(row?.errorReason?.contains("[transcribing]") == true)
        XCTAssertTrue(row?.errorReason?.contains("model timed out") == true)
    }

    func testMarkCancelledRecordsReason() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "parakeet")
        try await repo.markCancelled(id: job.id, reason: "user dismissed")
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .cancelled)
        XCTAssertEqual(row?.errorReason, "user dismissed")
    }

    func testListReturnsRowsInStatusFilteredByCreationOrder() async throws {
        let a = sampleJob("a")
        let b = sampleJob("b")
        let c = sampleJob("c")
        try await repo.insertQueued(job: a, engine: "parakeet")
        try await repo.insertQueued(job: b, engine: "parakeet")
        try await repo.insertQueued(job: c, engine: "parakeet")
        try await repo.updateStatus(id: a.id, status: .transcribing)
        try await repo.updateStatus(id: c.id, status: .transcribing)

        let queued = try await repo.list(status: .queued)
        let transcribing = try await repo.list(status: .transcribing)
        XCTAssertEqual(queued.map(\.id), [b.id.uuidString])
        XCTAssertEqual(Set(transcribing.map(\.id)), Set([a.id.uuidString, c.id.uuidString]))
    }

    func testDefaultTitleDerivedFromFilenameStemWhenAbsent() async throws {
        let job = FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/Team Sync 2026-05-27.m4a"),
            origin: .dragDrop
        )!
        try await repo.insertQueued(job: job, engine: "parakeet")
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.title, "Team Sync 2026-05-27")
    }

    // MARK: - kind / origin (schema v29)

    func testInsertPersistsKindAndOrigin() async throws {
        let video = FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/clip.mp4"), origin: .watchedFolder
        )!
        let memo = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/voice-memo-1.caf"),
            kind: .voiceMemo, origin: .voiceMemoCapture
        )
        try await repo.insertQueued(job: video, engine: "parakeet")
        try await repo.insertQueued(job: memo, engine: "parakeet")

        let videoRow = try await repo.fetch(id: video.id)
        XCTAssertEqual(videoRow?.kind, .video)
        XCTAssertEqual(videoRow?.origin, .watchedFolder)

        let memoRow = try await repo.fetch(id: memo.id)
        XCTAssertEqual(memoRow?.kind, .voiceMemo)
        XCTAssertEqual(memoRow?.origin, .voiceMemoCapture)
    }

    func testListByOriginsSplitsFilesFromVoiceMemos() async throws {
        let dropped = sampleJob("dropped")  // .dragDrop
        let watched = FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/watched.m4a"), origin: .watchedFolder)!
        let captured = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/cap.caf"), kind: .voiceMemo, origin: .voiceMemoCapture)
        let synced = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/sync.m4a"), kind: .voiceMemo, origin: .voiceMemosSync)
        for job in [dropped, watched, captured, synced] {
            try await repo.insertQueued(job: job, engine: "parakeet")
        }

        let files = try await repo.list(origins: FileRecord.fileOrigins)
        XCTAssertEqual(Set(files.map(\.id)), Set([dropped.id.uuidString, watched.id.uuidString]))

        let memos = try await repo.list(origins: FileRecord.voiceMemoOrigins)
        XCTAssertEqual(Set(memos.map(\.id)), Set([captured.id.uuidString, synced.id.uuidString]))
    }

    func testListByOriginsFiltersByProjectAndOrdersNewestFirst() async throws {
        // files.project_id is a FK → projects(id), so the projects must exist.
        let projects = ProjectStore(database: db)
        let p = try await projects.create(name: "Scoped").id.uuidString
        let q = try await projects.create(name: "Other").id.uuidString
        let older = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/old.m4a"), kind: .audio, origin: .dragDrop, projectID: p)
        let newer = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/new.m4a"), kind: .audio, origin: .dragDrop, projectID: p)
        let other = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/other.m4a"), kind: .audio, origin: .dragDrop, projectID: q)
        try await repo.insertQueued(job: older, engine: "p", now: Date(timeIntervalSince1970: 1000))
        try await repo.insertQueued(job: newer, engine: "p", now: Date(timeIntervalSince1970: 2000))
        try await repo.insertQueued(job: other, engine: "p", now: Date(timeIntervalSince1970: 1500))

        let scoped = try await repo.list(origins: FileRecord.fileOrigins, projectID: p)
        XCTAssertEqual(scoped.map(\.id), [newer.id.uuidString, older.id.uuidString], "newest first, project-scoped")
    }

    func testListByEmptyOriginsReturnsNothing() async throws {
        try await repo.insertQueued(job: sampleJob(), engine: "p")
        let none = try await repo.list(origins: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testDeleteRemovesRow() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "p")
        try await repo.delete(id: job.id)
        let row = try await repo.fetch(id: job.id)
        XCTAssertNil(row)
    }

    func testDeleteAlsoRemovesEntryFtsRowSoSearchCannotGhost() async throws {
        let job = sampleJob()
        try await repo.insertQueued(job: job, engine: "p")
        try await db.exec(
            sql: """
                INSERT INTO entry_fts (item_id, source, project_id, title, started_at, sig, text)
                VALUES ('\(job.id.uuidString)', 'file', NULL, 'clip', 0, 'sig', 'searchable transcript text')
                """)

        try await repo.delete(id: job.id)

        let ftsCount = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM entry_fts WHERE item_id = '\(job.id.uuidString)'")
        XCTAssertEqual(ftsCount, 0, "deleting a file must purge its keyword-search row")
    }

    func testSourcePathsPresentReturnsOnlyExisting() async throws {
        let job = sampleJob("a")  // /tmp/a.m4a
        try await repo.insertQueued(job: job, engine: "p")
        let present = try await repo.sourcePathsPresent(["/tmp/a.m4a", "/tmp/not-there.m4a"])
        XCTAssertEqual(present, ["/tmp/a.m4a"])
        let empty = try await repo.sourcePathsPresent([])
        XCTAssertTrue(empty.isEmpty)
    }
}
