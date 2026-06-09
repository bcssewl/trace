import Foundation

/// Optional template + summarizer wiring.
///
/// When unset, the controller writes the
/// raw transcript to the markdown store and skips the summary stage.
public struct FileBatchSummarization: Sendable {
    public let template: Template
    public let summarizer: FileSummarizer
    public let projectID: UUID?

    public init(template: Template, summarizer: FileSummarizer, projectID: UUID? = nil) {
        self.template = template
        self.summarizer = summarizer
        self.projectID = projectID
    }
}

/// Top-level orchestrator for the file batch pipeline. Reads from a
/// `FileBatchQueue`, runs ingest → optional video-audio extraction →
/// transcription → optional summarization → markdown writeout → SQLite update
/// for one job at a time. Concurrency is intentionally one local transcription
/// at a time per the §4.1 spec; UI sends fresh jobs via `enqueue`, never via
/// direct controller mutation.
public actor FileBatchController {

    public struct ProjectFolderResolution: Sendable {
        public let projectFolderName: String
        public let sessionId: String

        public init(projectFolderName: String, sessionId: String) {
            self.projectFolderName = projectFolderName
            self.sessionId = sessionId
        }
    }

    private let queue: FileBatchQueue
    private let repository: FileRepository
    private let transcriber: FileTranscriber
    private let markdown: MarkdownStore
    private let processingState: ProcessingState
    private let folderResolver: @Sendable (FileBatchJob) -> ProjectFolderResolution
    private var runTask: Task<Void, Never>?
    private var isRunning = false
    private var didRunCrashRecovery = false

    /// How many times a crashed-out job is re-queued before being abandoned —
    /// the file itself may be what crashes the app.
    public static let maxRecoveryAttempts = 3

    public init(
        queue: FileBatchQueue,
        repository: FileRepository,
        transcriber: FileTranscriber,
        markdown: MarkdownStore,
        processingState: ProcessingState,
        folderResolver: @escaping @Sendable (FileBatchJob) -> ProjectFolderResolution
    ) {
        self.queue = queue
        self.repository = repository
        self.transcriber = transcriber
        self.markdown = markdown
        self.processingState = processingState
        self.folderResolver = folderResolver
    }

    /// Default folder resolver that places file transcripts under
    /// `<root>/inbox/<job.id>` so they land in the standard markdown layout
    /// without requiring a project assignment up front.
    public static func defaultFolderResolver() -> @Sendable (FileBatchJob) -> ProjectFolderResolution {
        { job in
            ProjectFolderResolution(
                projectFolderName: "inbox",
                sessionId: "file_\(job.id.uuidString.lowercased())"
            )
        }
    }

    /// Enqueue a job.
    ///
    /// Inserts the queued row, records the snapshot, and ensures
    /// the run loop is awake.
    public func enqueue(_ job: FileBatchJob, engine: String) async throws {
        try await repository.insertQueued(job: job, engine: engine)
        try await queue.enqueue(job)
        await processingState.record(job: job, status: .queued)
    }

    /// Cancel a job by id.
    ///
    /// If still queued, it is removed immediately and the
    /// row is moved to `.cancelled` so the UI updates synchronously. If already
    /// in flight, the active pipeline stages observe the cancellation between
    /// steps and surface a `.cancelled` terminal state.
    public func cancel(id: UUID) async throws {
        let record = try await repository.fetch(id: id)
        await queue.cancel(id: id)
        guard let record else { return }
        guard record.status == .queued else { return }
        try await repository.markCancelled(id: id)
        // Republish the snapshot using whatever job-shaped data we have so the
        // UI sees a terminal row even though the controller never dequeued it.
        // The persisted `kind`/`origin` (schema v29) avoid guessing from the
        // extension and keep the cancelled row in its correct surface.
        let surrogateJob = FileBatchJob(
            id: id,
            sourceURL: URL(fileURLWithPath: record.sourcePath),
            kind: record.kind,
            origin: record.origin
        )
        await processingState.record(
            job: surrogateJob, status: .cancelled, errorReason: "user cancelled"
        )
    }

    /// Drives the queue to drain.
    ///
    /// Returns once empty. Use this from a long-
    /// running supervisor; `startRunLoop` wraps it in a Task so callers can
    /// fire-and-forget.
    public func runUntilDrained(
        locale: Locale = .current,
        summarization: FileBatchSummarization? = nil
    ) async {
        while let job = await queue.dequeue() {
            if await queue.consumeCancellation(id: job.id) {
                await applyCancellation(job: job)
                continue
            }
            await processSingleJob(
                job, locale: locale, summarization: summarization
            )
        }
    }

    /// Start a background task that drains the queue until empty.
    ///
    /// Calling
    /// `enqueue` later wakes the loop again only if it has finished. Designed
    /// for a single supervisor at any time. The first run also performs crash
    /// recovery (`recoverInterruptedJobs`) so rows a previous process left
    /// stuck in a non-terminal status get retried even when the controller was
    /// constructed lazily.
    public func startRunLoop(
        locale: Locale = .current,
        summarization: FileBatchSummarization? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        runTask = Task { [self] in
            if !didRunCrashRecovery {
                do {
                    _ = try await self.recoverInterruptedJobs()
                } catch {
                    Loggers.files.error(
                        "Crash recovery for interrupted file jobs failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            await self.runUntilDrained(locale: locale, summarization: summarization)
            self.markStopped()
        }
    }

    // MARK: Crash recovery

    /// Outcome of `recoverInterruptedJobs` — what was re-queued and what was
    /// abandoned (marked failed after too many interrupted attempts).
    public struct RecoveryReport: Sendable, Equatable {
        public var requeued: [UUID] = []
        public var abandoned: [UUID] = []
        public init() {}
    }

    /// Re-queue jobs a previous process left stuck in a non-terminal status
    /// (the in-memory queue dies with the process; without this, a crash mid-
    /// transcription showed "Transcribing…" forever and never retried).
    ///
    /// Rows already interrupted `maxRecoveryAttempts` times are marked failed
    /// with a clear, user-visible reason instead — the file itself may be what
    /// crashes the app. Idempotent within one controller lifetime; call it at
    /// boot (then `startRunLoop()` if it reports re-queued jobs).
    @discardableResult
    public func recoverInterruptedJobs(
        maxAttempts: Int = FileBatchController.maxRecoveryAttempts
    ) async throws -> RecoveryReport {
        var report = RecoveryReport()
        guard !didRunCrashRecovery else { return report }
        didRunCrashRecovery = true

        for record in try await repository.nonTerminalRecords() {
            guard let id = UUID(uuidString: record.id) else { continue }
            let job = FileBatchJob(
                id: id,
                sourceURL: URL(fileURLWithPath: record.sourcePath),
                kind: record.kind,
                origin: record.origin,
                projectID: record.projectID
            )
            let attempts = try await repository.recoveryAttempts(id: id)
            if attempts >= maxAttempts {
                let reason =
                    "Processing was interrupted \(attempts + 1) times (the app quit mid-job). "
                    + "Giving up on automatic retries — use Retry to try again manually."
                try await repository.markFailed(
                    id: id,
                    failure: FileBatchFailure(stage: record.status, reason: reason)
                )
                await processingState.record(job: job, status: .failed, errorReason: reason)
                report.abandoned.append(id)
                Loggers.files.error(
                    "Abandoned interrupted job \(id.uuidString, privacy: .public) after \(attempts) recovery attempt(s)"
                )
                continue
            }
            try await repository.markRequeuedForRecovery(id: id)
            await queue.tryEnqueue(job)
            await processingState.record(job: job, status: .queued)
            report.requeued.append(id)
            Loggers.files.info(
                "Re-queued interrupted job \(id.uuidString, privacy: .public) (attempt \(attempts + 1))"
            )
        }
        return report
    }

    /// Wait for the current run loop iteration to finish, if any.
    ///
    /// Returns
    /// immediately when no loop is active.
    public func awaitDrain() async {
        if let task = runTask { _ = await task.value }
    }

    private func markStopped() {
        isRunning = false
        runTask = nil
    }

    private func processSingleJob(
        _ job: FileBatchJob,
        locale: Locale,
        summarization: FileBatchSummarization?
    ) async {
        do {
            try await transition(job: job, to: .transcribing)
            let result = try await runTranscribeStage(job: job, locale: locale)

            if await wasCancelled(job: job) {
                await applyCancellation(job: job)
                return
            }

            let finalMarkdown: String
            if let summarization {
                try await transition(job: job, to: .summarizing)
                let summary = try await summarization.summarizer.summarize(
                    transcript: result.text,
                    template: summarization.template,
                    projectID: summarization.projectID
                )
                finalMarkdown = summary.markdown
            } else {
                finalMarkdown = result.text
            }

            if await wasCancelled(job: job) {
                await applyCancellation(job: job)
                return
            }

            try await transition(job: job, to: .writing)
            let layout = try writeTranscriptMarkdown(
                job: job,
                transcript: result.text,
                summary: summarization == nil ? nil : finalMarkdown
            )

            try await repository.markCompleted(
                id: job.id,
                transcriptPath: layout.notesURL.path,
                durationMs: result.durationMs
            )
            await processingState.record(job: job, status: .completed)
        } catch let err as TraceError {
            await applyFailure(job: job, error: err)
        } catch {
            await applyFailure(
                job: job,
                error: TraceError.modelProviderFailed(
                    provider: "file-batch", underlying: error
                ))
        }
        await transcriber.cleanupTemporaryFiles()
    }

    private func wasCancelled(job: FileBatchJob) async -> Bool {
        await queue.isCancelled(id: job.id)
    }

    private func runTranscribeStage(
        job: FileBatchJob, locale: Locale
    ) async throws -> FileTranscriptionResult {
        let stateRecorder = processingState
        let repoRecorder = repository
        return try await transcriber.transcribe(job, locale: locale) { stage in
            try? await repoRecorder.updateStatus(id: job.id, status: stage)
            await stateRecorder.record(job: job, status: stage)
        }
    }

    private func transition(job: FileBatchJob, to status: FileBatchStatus) async throws {
        try await repository.updateStatus(id: job.id, status: status)
        await processingState.record(job: job, status: status)
    }

    private func applyCancellation(job: FileBatchJob) async {
        _ = await queue.consumeCancellation(id: job.id)
        do {
            try await repository.markCancelled(id: job.id)
        } catch {
            Loggers.files.error("markCancelled failed: \(String(describing: error), privacy: .public)")
        }
        await processingState.record(
            job: job, status: .cancelled, errorReason: "user cancelled"
        )
    }

    private func applyFailure(job: FileBatchJob, error: TraceError) async {
        let stage = inferFailureStage(job: job, error: error)
        let failure = FileBatchFailure(stage: stage, reason: error.localizedDescription)
        // The DB write and the UI snapshot must agree: if the write fails the
        // row stays in a non-terminal status while the UI shows "failed", and
        // nothing ever reconciles them within this session. Retry once
        // (transient lock contention is the usual cause); if it still fails,
        // say so in the surfaced reason — start-up recovery will re-queue the
        // stuck row on next launch, so the user knows what to expect.
        var persistFailure: (any Error)?
        for _ in 0..<2 {
            do {
                try await repository.markFailed(id: job.id, failure: failure)
                persistFailure = nil
                break
            } catch {
                persistFailure = error
            }
        }
        var surfacedReason = error.localizedDescription
        if let persistFailure {
            Loggers.files.error(
                "markFailed could not be persisted for \(job.id.uuidString, privacy: .public): \(String(describing: persistFailure), privacy: .public)"
            )
            surfacedReason +=
                " (this failure could not be saved — the job will be retried automatically on next launch)"
        }
        await processingState.record(
            job: job, status: .failed, errorReason: surfacedReason
        )
        Loggers.files.error(
            "Job \(job.id.uuidString, privacy: .public) failed at \(stage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    private func inferFailureStage(job: FileBatchJob, error: TraceError) -> FileBatchStatus {
        switch error.category {
        case .audio: return .extracting
        case .speech: return .transcribing
        case .model: return .summarizing
        case .storage: return .writing
        default: return .transcribing
        }
    }

    private func writeTranscriptMarkdown(
        job: FileBatchJob,
        transcript: String,
        summary: String?
    ) throws -> SessionLayout {
        let resolution = folderResolver(job)
        let layout = try markdown.layout(
            projectFolderName: resolution.projectFolderName,
            sessionId: resolution.sessionId
        )
        try layout.createDirectories()
        let body = Self.renderMarkdownBody(
            job: job, transcript: transcript, summary: summary
        )
        try markdown.writeNotes(body, to: layout)
        return layout
    }

    private static func renderMarkdownBody(
        job: FileBatchJob, transcript: String, summary: String?
    ) -> String {
        var lines: [String] = []
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        let displayName = stem.isEmpty ? "Untitled" : stem
        lines.append("# \(displayName)")
        lines.append("")
        lines.append("- Source: \(job.sourceURL.lastPathComponent)")
        lines.append("- Origin: \(job.origin.rawValue)")
        lines.append("- Kind: \(job.kind.rawValue)")
        lines.append("")
        if let summary {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }
}
