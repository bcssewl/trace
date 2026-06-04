@preconcurrency import AVFoundation
import Foundation

/// One-shot voice memo recorder.
///
/// Streams microphone buffers from `MicCapture`,
/// resamples to the canonical archive format (`AudioFormat.canonicalArchive`),
/// and writes a CAF file to disk. Returns a `FileBatchJob` so callers feed
/// the controller without writing wedge-specific glue.
///
/// `VoiceMemoCapture` is an actor: it owns the recording task, the writer,
/// and the converter lifetime. Tests can substitute the capture source via
/// `MicrophoneBufferProducing`.
public protocol MicrophoneBufferProducing: Sendable {
    func start() throws
    func stop()
    /// A fresh buffer stream for THIS recording. Each call returns an independent
    /// subscriber, so repeated record cycles each get their own live stream — the
    /// legacy single-shot `buffers` is consumed once and then dead, which is what
    /// left the second memo recording silently empty.
    func subscribe() -> AsyncStream<AVAudioPCMBuffer>
}

extension MicCapture: MicrophoneBufferProducing {}

public actor VoiceMemoCapture {

    public enum State: Sendable, Equatable {
        case idle
        case recording
        case finalizing
        case finished(url: URL, durationMs: Int64)
        case failed(reason: String)
    }

    private let mic: any MicrophoneBufferProducing
    private let outputDirectory: URL
    private let archiveFormat: AVAudioFormat
    private var task: Task<Void, Never>?
    private(set) var state: State = .idle
    private var pendingURL: URL?
    private var convertedFrames: Int64 = 0
    private let stopFlag = SyncBool(initial: false)

    public init(
        mic: any MicrophoneBufferProducing = MicCapture(),
        outputDirectory: URL,
        archiveFormat: AVAudioFormat = AudioFormat.canonicalASR
    ) {
        self.mic = mic
        self.outputDirectory = outputDirectory
        self.archiveFormat = archiveFormat
    }

    /// Start a fresh recording.
    ///
    /// Throws if a recording is already in flight.
    public func start() throws {
        guard state == .idle else {
            throw TraceError.audioCaptureFailed(
                reason: "VoiceMemoCapture.start called while in \(state)"
            )
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDirectory.path) {
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        let timestamp = Self.fileNameTimestamp()
        let url = outputDirectory.appendingPathComponent("voice-memo-\(timestamp).caf")
        pendingURL = url
        convertedFrames = 0
        stopFlag.value = false

        let archiveFormat = archiveFormat
        let micSource = mic
        let stopFlag = stopFlag
        let writer = try AVAudioFile(forWriting: url, settings: archiveFormat.settings)

        try micSource.start()
        state = .recording

        // Subscribe inside the consuming task so the fresh per-recording stream is
        // created and consumed entirely within one isolation domain. Each cycle
        // gets its own subscriber — the legacy single-shot `buffers` is consumed
        // once and then dead, which left a second memo recording silently empty.
        task = Task { [weak self] in
            await self?.consumeMicBuffers(
                stream: micSource.subscribe(), writer: writer,
                archiveFormat: archiveFormat, stopFlag: stopFlag
            )
        }
    }

    /// Stop the current recording.
    ///
    /// Awaits the writer drain and returns the
    /// resulting `FileBatchJob` referring to the freshly-written CAF.
    public func stop(
        projectID: String? = nil, templateID: String? = nil
    ) async throws -> FileBatchJob {
        guard state == .recording else {
            throw TraceError.audioCaptureFailed(
                reason: "VoiceMemoCapture.stop called while not recording (state=\(state))"
            )
        }
        state = .finalizing
        stopFlag.value = true
        mic.stop()
        // The real mic keeps its engine warm on `stop()` and does NOT finish the
        // buffer stream, so the consume loop would block on `await` forever waiting
        // for a buffer that never comes. Cancelling the task makes the AsyncStream
        // iterator return nil, ending the loop and letting it finalise the file.
        task?.cancel()
        if let task { _ = await task.value }
        self.task = nil

        switch state {
        case .finished(let url, let durationMs):
            // No audio captured (mic delivered nothing) — discard the empty file and
            // fail loudly rather than queue a zero-length memo that transcribes to
            // nothing.
            guard durationMs > 0 else {
                try? FileManager.default.removeItem(at: url)
                pendingURL = nil
                state = .idle
                throw TraceError.audioCaptureFailed(reason: "No audio was captured")
            }
            let job = FileBatchJob(
                sourceURL: url,
                kind: .voiceMemo,
                origin: .voiceMemoCapture,
                priority: 0,
                projectID: projectID,
                templateID: templateID,
                asrTaskOverride: .voiceMemo
            )
            pendingURL = nil
            state = .idle
            return job
        case .failed(let reason):
            // Don't leave a truncated partial recording orphaned on disk.
            if let url = pendingURL { try? FileManager.default.removeItem(at: url) }
            pendingURL = nil
            state = .idle
            throw TraceError.audioCaptureFailed(reason: reason)
        default:
            if let url = pendingURL { try? FileManager.default.removeItem(at: url) }
            pendingURL = nil
            state = .idle
            throw TraceError.audioCaptureFailed(reason: "VoiceMemoCapture ended in unexpected state \(state)")
        }
    }

    /// Cancel an active recording.
    ///
    /// Discards the partial output file.
    public func cancel() async {
        guard state == .recording else { return }
        stopFlag.value = true
        mic.stop()
        task?.cancel()
        if let task { _ = await task.value }
        self.task = nil
        if let url = pendingURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingURL = nil
        convertedFrames = 0
        state = .idle
    }

    private func consumeMicBuffers(
        stream: sending AsyncStream<AVAudioPCMBuffer>,
        writer: AVAudioFile,
        archiveFormat: AVAudioFormat,
        stopFlag: SyncBool
    ) async {
        var converter: AudioConverter?
        var frames: Int64 = 0
        do {
            for await buffer in stream {
                if stopFlag.value { break }
                if converter == nil {
                    converter = try AudioConverter(
                        inputFormat: buffer.format, outputFormat: archiveFormat
                    )
                } else if let conv = converter, conv.currentInputSampleRate != buffer.format.sampleRate {
                    try conv.rebuildForMeasuredRate(buffer.format.sampleRate)
                }
                guard let conv = converter else { continue }
                let outBuffer = try conv.convert(buffer)
                try writer.write(from: outBuffer)
                frames += Int64(outBuffer.frameLength)
            }
            let durationMs = Int64((Double(frames) / max(archiveFormat.sampleRate, 1)) * 1000)
            finalize(state: .finished(url: writer.url, durationMs: durationMs), frames: frames)
        } catch {
            finalize(state: .failed(reason: error.localizedDescription), frames: frames)
        }
    }

    private func finalize(state newState: State, frames: Int64) {
        self.convertedFrames = frames
        self.state = newState
    }

    private static func fileNameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
