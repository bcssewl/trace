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
    /// for a single supervisor at any time.
    public func startRunLoop(
        locale: Locale = .current,
        summarization: FileBatchSummarization? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        runTask = Task { [self] in
            await self.runUntilDrained(locale: locale, summarization: summarization)
            self.markStopped()
        }
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
        do {
            try await repository.markFailed(id: job.id, failure: failure)
        } catch {
            Loggers.files.error("markFailed failed: \(String(describing: error), privacy: .public)")
        }
        await processingState.record(
            job: job, status: .failed, errorReason: error.localizedDescription
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
