@preconcurrency import AVFoundation
import Foundation
import Speech
import os

/// Retry/pacing policy for Apple Speech segment requests.
///
/// Long meetings fire one `SFSpeechRecognizer` request per speech segment;
/// Apple throttles bursts and long sessions, and a throttled request used to
/// hang until the long safety timeout and then be silently dropped. The policy
/// is a plain value type so the backoff math and the rate-limit classification
/// are unit-testable without touching the Speech framework.
public struct AppleSpeechRetryPolicy: Sendable, Equatable {
    /// Total tries per segment (1 initial + `maxAttempts - 1` retries).
    public var maxAttempts: Int
    /// Backoff before the first retry; doubles each retry after that.
    public var initialBackoff: TimeInterval
    public var backoffMultiplier: Double
    public var maxBackoff: TimeInterval
    /// Minimum spacing between consecutive request starts — modest pacing so a
    /// burst of short segments doesn't trip the throttle in the first place.
    public var minimumRequestGap: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialBackoff: TimeInterval = 0.5,
        backoffMultiplier: Double = 2,
        maxBackoff: TimeInterval = 8,
        minimumRequestGap: TimeInterval = 0.25
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoff = initialBackoff
        self.backoffMultiplier = backoffMultiplier
        self.maxBackoff = maxBackoff
        self.minimumRequestGap = minimumRequestGap
    }

    /// Delay before retry number `retry` (1-based: the first retry waits
    /// `initialBackoff`, the second `initialBackoff * multiplier`, …), capped
    /// at `maxBackoff`.
    public func backoff(beforeRetry retry: Int) -> TimeInterval {
        let exponent = max(0, retry - 1)
        let raw = initialBackoff * pow(backoffMultiplier, Double(exponent))
        return min(raw, maxBackoff)
    }

    /// Does this error look like a transient rate-limit/denial worth retrying?
    ///
    /// Apple doesn't document a stable error contract for throttling, so this
    /// combines the one widely observed concrete case (kAFAssistantErrorDomain
    /// code 203 "Retry") with a conservative wording heuristic. Anything else
    /// (format failures, unsupported locale, cancellation) fails fast.
    public static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain", ns.code == 203 {
            return true
        }
        let pieces = [
            ns.localizedDescription,
            ns.localizedFailureReason ?? "",
            (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "",
        ]
        let text = pieces.joined(separator: " ").lowercased()
        let markers = ["rate limit", "rate-limit", "throttl", "too many", "busy", "retry", "overload"]
        return markers.contains { text.contains($0) }
    }
}

/// Process-wide FIFO gate for Apple Speech requests.
///
/// The meeting runtime resolves a SEPARATE backend instance per audio stream
/// (mic + system), but Apple's throttle is system-wide — so serialisation and
/// pacing must be shared across instances. One segment is recognised at a
/// time, in submission order, with `minimumGap` between request starts.
public final class AppleSpeechRequestGate: @unchecked Sendable {
    public static let shared = AppleSpeechRequestGate()

    private struct GateState: Sendable {
        var tail: Task<Void, Never>?
        var lastRequestStart: ContinuousClock.Instant?
    }

    private let state: OSAllocatedUnfairLock<GateState>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: GateState())
    }

    /// Run `body` once every previously enqueued request has finished and the
    /// pacing gap has elapsed. Errors propagate to the caller; a failed
    /// request never blocks the queue.
    public func withTurn<T: Sendable>(
        minimumGap: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let stateLock = state
        // Read the previous tail and append ourselves in ONE locked critical
        // section so concurrent callers chain in submission order.
        let work: Task<T, Error> = stateLock.withLock { gateState in
            let previous = gateState.tail
            let work = Task<T, Error> {
                await previous?.value
                // Pacing: keep request STARTS at least `minimumGap` apart.
                if minimumGap > 0, let last = stateLock.withLock({ $0.lastRequestStart }) {
                    let gap = Duration.seconds(minimumGap)
                    let since = ContinuousClock.now - last
                    if since < gap {
                        try? await Task.sleep(for: gap - since)
                    }
                }
                stateLock.withLock { $0.lastRequestStart = ContinuousClock.now }
                return try await body()
            }
            gateState.tail = Task { _ = try? await work.value }
            return work
        }
        return try await work.value
    }
}

public actor AppleSpeechBackend: TranscriptionBackend {
    public nonisolated let displayName = "Apple Speech"
    private var preparedLocale: Locale?
    private let policy: AppleSpeechRetryPolicy
    private let gate: AppleSpeechRequestGate

    public init(
        policy: AppleSpeechRetryPolicy = AppleSpeechRetryPolicy(),
        gate: AppleSpeechRequestGate = .shared
    ) {
        self.policy = policy
        self.gate = gate
    }

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
        let policy = self.policy
        // One Apple Speech request at a time, process-wide, modestly paced —
        // with retry + exponential backoff on transient throttling, and a TYPED
        // throw when the segment is finally dropped (never a silent loss): the
        // pipeline's health callback turns that into "N segments lost".
        return try await gate.withTurn(minimumGap: policy.minimumRequestGap) {
            var attempt = 1
            while true {
                do {
                    return try await Self.recognizeOnce(
                        samples: samples, locale: locale, previousContext: previousContext)
                } catch let error as TraceError {
                    // Structural failures (unsupported locale, buffer alloc,
                    // safety timeout) — not transient; fail fast.
                    throw error
                } catch {
                    let retryable = AppleSpeechRetryPolicy.isRetryable(error)
                    if retryable, attempt < policy.maxAttempts {
                        let delay = policy.backoff(beforeRetry: attempt)
                        Loggers.speech.warning(
                            "AppleSpeech rate-limited/transient failure (attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public)); backing off \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)"
                        )
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    if retryable {
                        throw TraceError.asrInferenceFailed(
                            engine: "apple-speech",
                            reason:
                                "rate-limited — segment dropped after \(attempt) attempts: \(error.localizedDescription)"
                        )
                    }
                    throw TraceError.asrInferenceFailed(
                        engine: "apple-speech", reason: error.localizedDescription)
                }
            }
        }
    }

    /// One recognition attempt. Throws the recognizer's RAW error (so the
    /// retry policy can classify it) for recognition failures, and `TraceError`
    /// for structural problems that no retry can fix.
    private static func recognizeOnce(
        samples: [Float], locale: Locale, previousContext: String?
    ) async throws -> String {
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
                    // Throw the RAW error — the retry loop classifies it for
                    // rate-limit backoff before mapping to TraceError.
                    once.resume(throwing: error)
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
