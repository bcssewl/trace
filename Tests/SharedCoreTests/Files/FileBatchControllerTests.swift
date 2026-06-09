import XCTest

@testable import SharedCore

final class FileBatchControllerTests: XCTestCase {

    actor StubReader: AudioFileReading {
        let result: AudioReadResult
        init(result: AudioReadResult) { self.result = result }
        func read(url: URL) async throws -> AudioReadResult { result }
    }

    actor StubExtractor: VideoAudioExtracting {
        let output: URL
        init(output: URL) { self.output = output }
        func extractAudio(from videoURL: URL) async throws -> URL { output }
    }

    actor StubBackend: SampleTranscribing {
        nonisolated let engineLabel = "Stub"
        private let text: String
        init(text: String) { self.text = text }
        func transcribeSamples(
            _ samples: [Float], locale: Locale, previousContext: String?
        ) async throws -> String { text }
    }

    actor FailingBackend: SampleTranscribing {
        nonisolated let engineLabel = "Failing"
        func transcribeSamples(
            _ samples: [Float], locale: Locale, previousContext: String?
        ) async throws -> String {
            throw TraceError.asrInferenceFailed(engine: "Failing", reason: "model crashed")
        }
    }

    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var markdown: MarkdownStore!
    private var repo: FileRepository!
    private var queue: FileBatchQueue!
    private var state: ProcessingState!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-ctrl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let mdRoot = tempDir.appendingPathComponent("markdown", isDirectory: true)
        try FileManager.default.createDirectory(at: mdRoot, withIntermediateDirectories: true)
        markdown = MarkdownStore(folderConfig: MarkdownFolderConfig(displayPath: mdRoot.path))
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        // Full schema so the files table carries the v29 kind/origin columns.
        try await AppSchema.bootstrap(database: db)
        repo = FileRepository(database: db)
        queue = FileBatchQueue(capacity: 16)
        state = ProcessingState()
    }

    override func tearDown() async throws {
        try await db.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleJob(_ name: String = "clip", priority: Int = 0) -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            origin: .dragDrop, priority: priority
        )!
    }

    private func makeTranscriber(text: String) -> FileTranscriber {
        let reader = StubReader(result: AudioReadResult(samples: [0, 0, 0], durationMs: 3_000))
        let extractor = StubExtractor(output: URL(fileURLWithPath: "/tmp/x.m4a"))
        let backend = StubBackend(text: text)
        return FileTranscriber(reader: reader, extractor: extractor) { _, _ in backend }
    }

    func testHappyPathWritesTranscriptAndUpdatesRepository() async throws {
        let transcriber = makeTranscriber(text: "Hello, file batch.")
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        let job = sampleJob()
        try await controller.enqueue(job, engine: "stub:1")
        await controller.runUntilDrained()

        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertNotNil(row?.transcriptPath)
        let transcriptURL = URL(fileURLWithPath: row!.transcriptPath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        let body = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(body.contains("Hello, file batch."))
        XCTAssertEqual(row?.durationMs, 3_000)
    }

    func testFailureDuringTranscriptionMarksJobFailed() async throws {
        let extractor = StubExtractor(output: URL(fileURLWithPath: "/tmp/x.m4a"))
        let reader = StubReader(result: AudioReadResult(samples: [0], durationMs: 0))
        let backend = FailingBackend()
        let transcriber = FileTranscriber(reader: reader, extractor: extractor) { _, _ in backend }
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        let job = sampleJob()
        try await controller.enqueue(job, engine: "stub:1")
        await controller.runUntilDrained()

        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .failed)
        XCTAssertTrue(row?.errorReason?.contains("transcribing") == true)
    }

    func testCancelledJobDoesNotWriteTranscript() async throws {
        let transcriber = makeTranscriber(text: "should never persist")
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        let job = sampleJob()
        try await controller.enqueue(job, engine: "stub:1")
        try await controller.cancel(id: job.id)
        await controller.runUntilDrained()

        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .cancelled)
        XCTAssertNil(row?.transcriptPath)
    }

    func testProcessingStateRecordsAllStageTransitions() async throws {
        let transcriber = makeTranscriber(text: "complete")
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        let job = sampleJob()

        // Collect snapshots emitted during processing.
        let collector = SnapshotCollector()
        let subscription = await state.subscribe()
        let jobId = job.id
        let task = Task { [collector] in
            for await snapshots in subscription {
                await collector.replace(snapshots)
                let lastStatus = snapshots.first(where: { $0.id == jobId })?.status
                if lastStatus == .completed || lastStatus == .failed || lastStatus == .cancelled {
                    break
                }
            }
        }

        try await controller.enqueue(job, engine: "stub:1")
        await controller.runUntilDrained()
        _ = await task.value

        let observed = await collector.observedStatuses(for: job.id)
        XCTAssertTrue(observed.contains(.queued))
        XCTAssertTrue(observed.contains(.transcribing))
        XCTAssertTrue(observed.contains(.completed))
    }

    func testHigherPriorityRunsFirstWhenDrained() async throws {
        let transcriber = makeTranscriber(text: "ok")
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )

        let low = sampleJob("low", priority: 0)
        let high = sampleJob("high", priority: 100)
        try await controller.enqueue(low, engine: "stub:1")
        try await controller.enqueue(high, engine: "stub:1")
        await controller.runUntilDrained()

        let lowRow = try await repo.fetch(id: low.id)
        let highRow = try await repo.fetch(id: high.id)
        XCTAssertEqual(lowRow?.status, .completed)
        XCTAssertEqual(highRow?.status, .completed)
        XCTAssertNotNil(lowRow?.completedAt)
        XCTAssertNotNil(highRow?.completedAt)
        let lowFinished = lowRow!.completedAt!.timeIntervalSince1970
        let highFinished = highRow!.completedAt!.timeIntervalSince1970
        XCTAssertLessThanOrEqual(highFinished, lowFinished)
    }

    // MARK: Crash recovery

    private func makeController(text: String = "recovered") -> FileBatchController {
        FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: makeTranscriber(text: text),
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
    }

    func testRecoverInterruptedJobsRequeuesStuckRow() async throws {
        // Simulate a crash mid-transcription: row stuck non-terminal, queue empty.
        let job = sampleJob("stuck")
        try await repo.insertQueued(job: job, engine: "stub:1")
        try await repo.updateStatus(id: job.id, status: .transcribing)

        let controller = makeController()
        let report = try await controller.recoverInterruptedJobs()

        XCTAssertEqual(report.requeued, [job.id])
        XCTAssertTrue(report.abandoned.isEmpty)
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .queued)
        let queuedIds = await queue.snapshotIds()
        XCTAssertEqual(queuedIds, [job.id])
        let attempts = try await repo.recoveryAttempts(id: job.id)
        XCTAssertEqual(attempts, 1)
    }

    func testRecoveredJobRunsToCompletion() async throws {
        let job = sampleJob("stuck-then-done")
        try await repo.insertQueued(job: job, engine: "stub:1")
        try await repo.updateStatus(id: job.id, status: .summarizing)

        let controller = makeController(text: "second time lucky")
        _ = try await controller.recoverInterruptedJobs()
        await controller.runUntilDrained()

        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertNotNil(row?.transcriptPath)
    }

    func testRecoveryAbandonsJobAfterMaxAttemptsWithClearReason() async throws {
        let job = sampleJob("crash-loop")
        try await repo.insertQueued(job: job, engine: "stub:1")
        try await repo.updateStatus(id: job.id, status: .transcribing)
        // Already re-queued the maximum number of times by previous launches.
        for _ in 0..<FileBatchController.maxRecoveryAttempts {
            try await repo.markRequeuedForRecovery(id: job.id)
        }
        try await repo.updateStatus(id: job.id, status: .transcribing)

        let controller = makeController()
        let report = try await controller.recoverInterruptedJobs()

        XCTAssertEqual(report.abandoned, [job.id])
        XCTAssertTrue(report.requeued.isEmpty)
        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .failed)
        XCTAssertTrue(row?.errorReason?.contains("interrupted") == true)
        XCTAssertTrue(row?.errorReason?.contains("Retry") == true, "reason must point at the manual Retry action")
        let queuedIds = await queue.snapshotIds()
        XCTAssertTrue(queuedIds.isEmpty)
    }

    func testRecoveryIgnoresTerminalRows() async throws {
        let done = sampleJob("done")
        try await repo.insertQueued(job: done, engine: "stub:1")
        try await repo.markCompleted(id: done.id, transcriptPath: "/tmp/t.md", durationMs: 100)
        let failed = sampleJob("failed")
        try await repo.insertQueued(job: failed, engine: "stub:1")
        try await repo.markFailed(
            id: failed.id, failure: FileBatchFailure(stage: .transcribing, reason: "x"))

        let controller = makeController()
        let report = try await controller.recoverInterruptedJobs()

        XCTAssertTrue(report.requeued.isEmpty)
        XCTAssertTrue(report.abandoned.isEmpty)
        let doneRow = try await repo.fetch(id: done.id)
        XCTAssertEqual(doneRow?.status, .completed)
    }

    func testRecoveryRunsOnlyOncePerControllerLifetime() async throws {
        let job = sampleJob("once")
        try await repo.insertQueued(job: job, engine: "stub:1")
        try await repo.updateStatus(id: job.id, status: .writing)

        let controller = makeController()
        let first = try await controller.recoverInterruptedJobs()
        XCTAssertEqual(first.requeued.count, 1)
        let second = try await controller.recoverInterruptedJobs()
        XCTAssertTrue(second.requeued.isEmpty, "recovery is idempotent within one controller lifetime")
        let attempts = try await repo.recoveryAttempts(id: job.id)
        XCTAssertEqual(attempts, 1)
    }

    func testSummarizationStageWritesSummarySection() async throws {
        let transcriber = makeTranscriber(text: "raw transcript text")
        let router = ScriptedModelRouter(scripted: [
            LLMDelta(textIncrement: "#### Summary\n"),
            LLMDelta(textIncrement: "all good.", isFinal: true),
        ])
        let summarizer = FileSummarizer(router: router)
        let template = Template.makeBuiltIn(
            id: UUID(), name: "FileSummary", description: "",
            systemPrompt: "{{transcript}}", outputSections: ["Summary"]
        )
        let summarization = FileBatchSummarization(template: template, summarizer: summarizer)
        let controller = FileBatchController(
            queue: queue,
            repository: repo,
            transcriber: transcriber,
            markdown: markdown,
            processingState: state,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        let job = sampleJob()
        try await controller.enqueue(job, engine: "stub:1")
        await controller.runUntilDrained(summarization: summarization)

        let row = try await repo.fetch(id: job.id)
        XCTAssertEqual(row?.status, .completed)
        let transcriptURL = URL(fileURLWithPath: row!.transcriptPath!)
        let body = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(body.contains("## Summary"))
        XCTAssertTrue(body.contains("all good."))
        XCTAssertTrue(body.contains("## Transcript"))
        XCTAssertTrue(body.contains("raw transcript text"))
    }
}

private actor SnapshotCollector {
    private var snapshots: [ProcessingSnapshot] = []
    private var allObserved: [UUID: [FileBatchStatus]] = [:]

    func replace(_ list: [ProcessingSnapshot]) {
        snapshots = list
        for snap in list {
            var current = allObserved[snap.id, default: []]
            if current.last != snap.status {
                current.append(snap.status)
            }
            allObserved[snap.id] = current
        }
    }

    func observedStatuses(for id: UUID) -> Set<FileBatchStatus> {
        Set(allObserved[id] ?? [])
    }
}
