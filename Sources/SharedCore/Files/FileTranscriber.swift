import Foundation

/// Result of one file transcription pass. `text` is the concatenated final
/// transcript; `audioURL` is the path actually decoded (the original for audio
/// inputs, an extracted temp file for video inputs); `durationMs` is the
/// source duration so callers can persist it to the `files` table.
public struct FileTranscriptionResult: Sendable, Hashable {
    public let jobID: UUID
    public let text: String
    public let audioURL: URL
    public let durationMs: Int64

    public init(jobID: UUID, text: String, audioURL: URL, durationMs: Int64) {
        self.jobID = jobID
        self.text = text
        self.audioURL = audioURL
        self.durationMs = durationMs
    }
}

/// Narrowed sample-only transcription contract. `FileTranscriber` consumes only
/// the offline file path of `TranscriptionBackend.transcribe(_:locale:previousContext:)`,
/// so production code adapts a `TranscriptionBackend` into a `SampleTranscribing`
/// and tests can stub a tiny `SampleTranscribing` actor without conforming to
/// the streaming method (which crosses non-Sendable AVAudioPCMBuffer).
public protocol SampleTranscribing: Sendable {
    var engineLabel: String { get }
    func transcribeSamples(
        _ samples: [Float], locale: Locale, previousContext: String?
    ) async throws -> String
}

/// Adapter that wraps any `TranscriptionBackend` as a `SampleTranscribing`.
///
/// Lives in production so the integration layer can register a real ASR engine
/// without changing the controller wiring.
public struct TranscriptionBackendAdapter: SampleTranscribing {
    public let engineLabel: String
    private let backend: any TranscriptionBackend

    public init(backend: any TranscriptionBackend) {
        self.engineLabel = backend.displayName
        self.backend = backend
    }

    /// Explicit-label variant — used when the label should reflect resolution
    /// context (e.g. a fallback) rather than just the backend's own name.
    public init(backend: any TranscriptionBackend, engineLabel: String) {
        self.engineLabel = engineLabel
        self.backend = backend
    }

    public func transcribeSamples(
        _ samples: [Float], locale: Locale, previousContext: String?
    ) async throws -> String {
        try await backend.transcribe(samples, locale: locale, previousContext: previousContext)
    }
}

/// Resolves a `FileBatchJob` to the audio URL the transcriber should decode
/// (the original for `audio` and `voiceMemo` kinds; an extracted temp file
/// for `video`).
public actor FileTranscriber {

    private let reader: any AudioFileReading
    private let extractor: any VideoAudioExtracting
    private let transcriberForTask: @Sendable (ASRTaskClass, UUID?) async -> (any SampleTranscribing)?
    private var temporaryFiles: Set<String> = []

    public init(
        reader: any AudioFileReading = FileAudioReader(),
        extractor: any VideoAudioExtracting = AVFoundationVideoAudioExtractor(),
        transcriberForTask: @escaping @Sendable (ASRTaskClass, UUID?) async -> (any SampleTranscribing)?
    ) {
        self.reader = reader
        self.extractor = extractor
        self.transcriberForTask = transcriberForTask
    }

    /// Stages required to drive the controller's `ProcessingState` mid-flight.
    ///
    /// Returned via the `onStage` closure rather than an `AsyncStream` so the
    /// caller (an actor) can mutate its own state in-line.
    public func transcribe(
        _ job: FileBatchJob,
        locale: Locale = .current,
        onStage: (@Sendable (FileBatchStatus) async -> Void)? = nil
    ) async throws -> FileTranscriptionResult {
        let resolvedAudioURL: URL
        switch job.kind {
        case .audio, .voiceMemo:
            resolvedAudioURL = job.sourceURL
        case .video:
            await onStage?(.extracting)
            let extracted = try await extractor.extractAudio(from: job.sourceURL)
            temporaryFiles.insert(extracted.path)
            resolvedAudioURL = extracted
        }

        await onStage?(.transcribing)
        let read = try await reader.read(url: resolvedAudioURL)

        let task = job.resolvedASRTask(locale: locale)
        let projectID = job.projectID.flatMap(UUID.init(uuidString:))
        guard let transcribing = await transcriberForTask(task, projectID) else {
            throw TraceError.asrModelMissing(
                engine: "(none registered)",
                model: task.rawValue
            )
        }

        let text: String
        do {
            text = try await transcribing.transcribeSamples(
                read.samples, locale: locale, previousContext: nil
            )
        } catch {
            throw TraceError.asrInferenceFailed(
                engine: transcribing.engineLabel,
                reason: error.localizedDescription
            )
        }

        return FileTranscriptionResult(
            jobID: job.id,
            text: text,
            audioURL: resolvedAudioURL,
            durationMs: read.durationMs
        )
    }

    /// Best-effort temp-file cleanup.
    ///
    /// Called once a job reaches any terminal
    /// state. Errors are swallowed: failing to delete a temp file is not
    /// recoverable and should never block the pipeline.
    public func cleanupTemporaryFiles() async {
        let snapshot = temporaryFiles
        temporaryFiles.removeAll()
        for path in snapshot {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
