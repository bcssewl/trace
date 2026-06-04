@preconcurrency import AVFoundation
import Foundation
import Speech

public actor AppleSpeechBackend: TranscriptionBackend {
    public nonisolated let displayName = "Apple Speech"
    private var preparedLocale: Locale?

    public init() {}

    public func checkStatus() async -> BackendStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .ready
        case .denied, .restricted: return .unavailable(reason: "Speech recognition denied")
        case .authorized: return preparedLocale == nil ? .ready : .loaded
        @unknown default: return .unavailable(reason: "Unknown Speech authorization")
        }
    }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        guard granted else {
            throw TraceError.permissionDenied(kind: .speechRecognition)
        }
        onStatus(.loaded)
        onProgress(1)
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        // Apple Speech needs a concrete language; auto-detect falls back to system.
        let locale = locale.concreteOrCurrent
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TraceError.asrInferenceFailed(
                engine: "apple-speech", reason: "recognizer unavailable for \(locale.identifier)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TraceError.asrInferenceFailed(
                engine: "apple-speech", reason: "on-device recognition unsupported for \(locale.identifier)")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if let previousContext { request.contextualStrings = [previousContext] }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else {
            throw TraceError.asrInferenceFailed(engine: "apple-speech", reason: "format build failed")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TraceError.asrInferenceFailed(engine: "apple-speech", reason: "buffer alloc failed")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: samples.count)
                }
            }
        }
        request.append(buffer)
        request.endAudio()

        Loggers.speech.info("AppleSpeech.transcribe begin samples=\(samples.count, privacy: .public)")
        // SFSpeechRecognizer's completion handler can fire more than once — a final
        // result is often followed by a trailing cancel/error callback. Resuming a
        // CheckedContinuation twice is a fatal runtime trap, so funnel every path
        // through a once-guard that resumes exactly once.
        let sampleCount = samples.count
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(c)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    Loggers.speech.error(
                        "AppleSpeech.transcribe error: \(error.localizedDescription, privacy: .public)"
                    )
                    once.resume(
                        throwing: TraceError.asrInferenceFailed(
                            engine: "apple-speech", reason: error.localizedDescription))
                    return
                }
                if let result, result.isFinal {
                    Loggers.speech.info(
                        "AppleSpeech.transcribe final len=\(result.bestTranscription.formattedString.count, privacy: .public)"
                    )
                    once.resume(returning: result.bestTranscription.formattedString)
                }
            }
            // Safety net: the recognizer can occasionally end a task without ever
            // reporting a final result OR an error. Without this, that segment's
            // await would hang forever. Time out (proportional to the audio length),
            // cancel the stuck task, and surface a normal error instead.
            let box = RecognitionTaskBox(task)
            Task {
                let seconds = Double(sampleCount) / 16_000.0 + 20.0
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.task.cancel()
                once.resume(
                    throwing: TraceError.asrInferenceFailed(
                        engine: "apple-speech", reason: "no result within \(Int(seconds))s"))
            }
        }
    }

    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        nil
    }

    public func clearModelCache() async {
        preparedLocale = nil
    }
}

/// Carries the non-`Sendable` `SFSpeechRecognitionTask` across to the timeout
/// closure so a stuck recognition can be cancelled.
private final class RecognitionTaskBox: @unchecked Sendable {
    let task: SFSpeechRecognitionTask
    init(_ task: SFSpeechRecognitionTask) { self.task = task }
}

/// Resumes a `CheckedContinuation` at most once. `SFSpeechRecognizer` invokes its
/// completion handler multiple times (and from an arbitrary queue), so the guard
/// is lock-protected and the second-and-later resume attempts are dropped instead
/// of trapping the runtime.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard let c = take() else { return }
        c.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let c = take() else { return }
        c.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
