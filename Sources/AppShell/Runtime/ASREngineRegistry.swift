@preconcurrency import AVFoundation
import Foundation
import SharedCore
import Speech

/// A live, session-based streaming transcriber used for the dictation live
/// preview.
///
/// Each engine that can stream provides its own implementation and
/// handles its OWN accumulation internally — Apple's chunk-merging lives in
/// `AppleSpeechStreamingTranscriber`; a clean cloud stream that already returns
/// cumulative text wouldn't need any. Batch-only engines simply have no
/// transcriber, and the pipeline transcribes the whole buffer on stop instead.
///
/// To add a streaming-capable engine (e.g. a future OpenRouter/cloud ASR that
/// supports server-side streaming), implement this protocol and return it from
/// `ASREngineRegistry.makeStreamingTranscriber(for:)`. Nothing else changes —
/// `BatchedASR` drives any conforming transcriber identically.
public protocol StreamingTranscriber: Sendable {
    /// Begin a streaming session. `onPartial` is invoked (off-main) with the
    /// cumulative transcript so far — already de-chunked by the implementation —
    /// for the live HUD. Returns `false` if streaming is unavailable so the
    /// caller can fall back to the batch path.
    func start(onPartial: @escaping @Sendable (String) -> Void) async -> Bool
    /// Feed a raw mic buffer; the implementation resamples as needed.
    func append(_ buffer: AVAudioPCMBuffer)
    /// End the session, wait for the final result, and return the complete
    /// transcript.
    func finish() async -> String
}

/// Central mapping from a dictation engine to its concrete transcription
/// components.
///
/// Exhaustive switches over `DictationASREngine` mean the compiler
/// forces every new engine to declare both a batch backend and its streaming
/// capability here — the mapping can't silently drift.
public enum ASREngineRegistry {
    /// The one-shot batch backend for an engine (always present). `cloudProvider`
    /// only matters for `.cloud`; local engines ignore it.
    ///
    /// Construction is centralized in `ASRBackendFactory` (SharedCore) — the
    /// registry only maps the engine choice to a route, so there's a single
    /// place that turns a route into a backend. The `??` is an unreachable
    /// safety net: every engine maps to a buildable route.
    public static func backend(
        for engine: DictationASREngine,
        cloudProvider: CloudASRProvider = .openai,
        localModelID: String? = nil
    ) -> any TranscriptionBackend {
        // A specific on-device model picked in the Settings catalog overrides the
        // engine's default variant: the catalog entry builds the exact backend
        // (Whisper Small vs Large, Qwen3 f32 vs Int8, Parakeet v2 vs v3). Only
        // honored when the model's family matches the coarse engine — a stale id
        // (engine changed elsewhere) or a streaming-only model falls through to
        // the engine's default route below.
        if engine != .cloud, let id = localModelID,
            let entry = catalogEntry(id, matching: engine),
            let backend = entry.makeBackend()
        {
            return backend
        }
        return ASRBackendFactory.makeBackend(for: engine.asrRoute(cloudProvider: cloudProvider))
            ?? AppleSpeechBackend()
    }

    /// The catalog entry for `id`, but only if its model family matches `engine`
    /// (so a persisted id can't drive a backend that disagrees with the coarse
    /// engine's streaming/cloud behavior). `nil` otherwise.
    private static func catalogEntry(_ id: String, matching engine: DictationASREngine) -> ASRModelEntry? {
        guard let entry = ASRModelCatalog.entry(id: id),
            entry.engine.coarseDictationEngine == engine
        else { return nil }
        return entry
    }

    /// A live streaming transcriber for the engine, or `nil` if it's batch-only.
    ///
    /// Returning `nil` makes the pipeline use the batch path — which is also the
    /// safe fallback for an engine that *claims* `supportsStreaming` but has no
    /// transcriber wired yet, and for a cloud provider without a realtime socket.
    public static func makeStreamingTranscriber(
        for engine: DictationASREngine,
        cloudProvider: CloudASRProvider = .openai
    ) -> (any StreamingTranscriber)? {
        switch engine {
        case .appleSpeech: return AppleSpeechStreamingTranscriber()
        case .parakeet, .whisperKit, .qwen3: return nil
        case .cloud:
            return cloudProvider.supportsStreaming ? DeepgramStreamingTranscriber() : nil
        }
    }
}

extension ASRModelEntry.Engine {
    /// The coarse `DictationASREngine` family a catalog model belongs to — the
    /// single place mapping a model's engine to its routing family (used both to
    /// guard a persisted model id against the active engine and to select one).
    var coarseDictationEngine: DictationASREngine {
        switch self {
        case .parakeet: return .parakeet
        case .qwen3: return .qwen3
        case .whisperKit: return .whisperKit
        case .appleSpeech: return .appleSpeech
        }
    }
}

extension DictationASREngine {
    /// The `ASRRoute` this dictation engine resolves to — the single mapping
    /// shared by `ASREngineRegistry` (dictation) and the meeting/file resolver
    /// (`RuntimeASRBackendResolver.resolve(engine:cloudProvider:)`), so
    /// engine→backend construction lives only in `ASRBackendFactory` and can't
    /// drift between the two call sites. `cloudProvider` is consulted only for
    /// `.cloud`.
    func asrRoute(cloudProvider: CloudASRProvider = .openai) -> ASRRoute {
        switch self {
        case .parakeet:
            return ASRRoute(engineIdentifier: "parakeet", modelIdentifier: "tdt-v3", allowsCloud: false)
        case .appleSpeech:
            return ASRRoute(engineIdentifier: "apple-speech", modelIdentifier: "on-device", allowsCloud: false)
        case .whisperKit:
            return ASRRoute(engineIdentifier: "whisperkit", modelIdentifier: "large-v3-turbo", allowsCloud: false)
        case .qwen3:
            return ASRRoute(engineIdentifier: "qwen3", modelIdentifier: "qwen3-asr-0.6b-int8", allowsCloud: false)
        case .cloud:
            return ASRRoute(engineIdentifier: cloudProvider.rawValue, modelIdentifier: "default", allowsCloud: true)
        }
    }
}

/// Apple `SFSpeechRecognizer`-backed live streaming.
///
/// Apple's on-device
/// recognizer emits the transcript in *chunks*: when it detects an endpoint (a
/// pause) it finalizes the current utterance and the next result's
/// `formattedString` RESETS to just the new chunk instead of accumulating. So
/// we accumulate ourselves — `committedText` holds finalized chunks,
/// `liveSegment` the one in progress.
public final class AppleSpeechStreamingTranscriber: StreamingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committedText = ""
    private var liveSegment = ""
    private var onPartial: (@Sendable (String) -> Void)?
    // Signals the recognizer has reached a terminal state (final result or
    // error) so `finish()` can release it without hanging.
    private var taskFinished = false
    private var teardownContinuation: CheckedContinuation<Void, Never>?

    public init() {}

    public func start(onPartial: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let recog = SFSpeechRecognizer(locale: .current), recog.isAvailable,
            recog.supportsOnDeviceRecognition
        else {
            Loggers.dictation.warning("Apple Speech streaming unavailable; falling back to batch ASR")
            return false
        }
        lock.withLock {
            committedText = ""
            liveSegment = ""
            taskFinished = false
            self.onPartial = onPartial
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        let newTask = recog.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let error {
                Loggers.dictation.error(
                    "Streaming recognizer error: \(error.localizedDescription, privacy: .public)"
                )
                self.signalFinished()
                return
            }
            guard let result else { return }
            let seg = result.bestTranscription.formattedString
            // Refinements of the current utterance share a long common prefix
            // with the live chunk; a fresh utterance after an endpoint does not,
            // so commit the finished chunk and begin a new one.
            if !seg.isEmpty {
                let display = self.lock.withLock { () -> String in
                    if self.liveSegment.isEmpty {
                        self.liveSegment = seg
                    } else {
                        let common = seg.commonPrefix(with: self.liveSegment).count
                        if common * 2 >= min(seg.count, self.liveSegment.count) {
                            self.liveSegment = seg
                        } else {
                            self.committedText = Self.joinChunks(self.committedText, self.liveSegment)
                            self.liveSegment = seg
                        }
                    }
                    return Self.joinChunks(self.committedText, self.liveSegment)
                }
                let handler = self.lock.withLock { self.onPartial }
                handler?(display)
            }
            if result.isFinal {
                self.lock.withLock {
                    self.committedText = Self.joinChunks(self.committedText, self.liveSegment)
                    self.liveSegment = ""
                }
                self.signalFinished()
            }
        }
        lock.withLock {
            recognizer = recog
            request = req
            task = newTask
        }
        Loggers.dictation.info("Apple Speech streaming session started")
        return true
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    public func finish() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                request?.endAudio()
                if taskFinished { return true }
                teardownContinuation = c
                return false
            }
            if resumeNow {
                c.resume()
            } else {
                // Safety: never block finalize forever if no terminal callback
                // arrives from the recognizer.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.forceTeardown()
                }
            }
        }
        return lock.withLock {
            task?.cancel()
            task = nil
            request = nil
            recognizer = nil
            onPartial = nil
            return Self.joinChunks(committedText, liveSegment)
        }
    }

    private func signalFinished() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            taskFinished = true
            let c = teardownContinuation
            teardownContinuation = nil
            return c
        }
        cont?.resume()
    }

    private func forceTeardown() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = teardownContinuation
            teardownContinuation = nil
            return c
        }
        cont?.resume()
    }

    /// Join two transcript chunks with a single space, skipping empties.
    static func joinChunks(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
