import AVFoundation
import AppKit
import Foundation
import MeetingModule
import SharedCore
@preconcurrency import Speech

@MainActor
public final class LiveDictationRuntime {
    public let controller: DictationController
    public let modeRegistry: ModeRegistry
    public let personalDictionary: PersonalDictionary
    public let historyStore: DictationHistoryStore
    public let audio: MicCapture
    public let pasteActor: AccessibilityPaste
    public let voiceMemo: VoiceMemoCapture

    private let asrAdapter: BatchedASR

    public init(
        database: SqliteDatabase,
        router: ModelRouter? = nil,
        asrEngine: DictationASREngine = .parakeet,
        cloudProvider: CloudASRProvider = .openai,
        localModelID: String? = nil,
        transcriptionLanguage: TranscriptionLanguage = .auto,
        deterministicCleanup: Bool = false,
        showLivePartials: Bool = false,
        onPartial: (@Sendable (String) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let registry = ModeRegistry(persistence: .sqlite(database))
        try await registry.bootstrap()
        let dictionary = PersonalDictionary(database: database)
        // Load vocab corrections from SQLite so user-taught fixes (e.g.
        // "pie torch" → "PyTorch") are applied between ASR and
        // paste. Without this `dictionary.apply(...)` only runs voice
        // punctuation rules (which are in-memory) and silently skips vocab.
        try await dictionary.bootstrap()
        let history = DictationHistoryStore(database: database)
        let paste = AccessibilityPaste()

        let mic = MicCapture()
        let backend = ASREngineRegistry.backend(
            for: asrEngine, cloudProvider: cloudProvider, localModelID: localModelID)
        // Live streaming preview only when the user enabled it AND the engine
        // actually provides a streaming transcriber. A batch-only engine — or a
        // future engine that declares `supportsStreaming` but has no transcriber
        // wired yet — gets nil here and cleanly uses the batch path.
        let streamer =
            showLivePartials
            ? ASREngineRegistry.makeStreamingTranscriber(for: asrEngine, cloudProvider: cloudProvider) : nil
        let asr = BatchedASR(
            backend: backend, mic: mic, streamer: streamer, locale: transcriptionLanguage.locale, onPartial: onPartial,
            onLevel: onLevel)
        try await asr.prepareBackend()
        Loggers.dictation.info(
            "Dictation ASR engine: \(asrEngine.rawValue, privacy: .public) streaming=\(streamer != nil, privacy: .public)"
        )

        // Real frontmost-app provider — pulled live every time the resolver
        // runs so the picked dictation Mode matches whatever app the user
        // actually has focused when they press the hotkey.
        let bundleIDProvider: @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let deps = LivePipelineDependencies(
            modeRegistry: registry,
            modeResolver: ModeResolver(
                registry: registry,
                bundleIDProvider: bundleIDProvider,
                // Per-website modes (BAS-5): real browser active-tab URL reader.
                browserTabReader: AppleScriptBrowserTabURLReader()
            ),
            personalDictionary: dictionary,
            historyStore: history,
            audio: LiveAudioAdapter(mic: mic),
            asr: asr,
            cleanup: RouterCleanup(router: router, deterministicOnly: deterministicCleanup),
            paste: LivePasteAdapter(paste: paste)
        )

        let fm = FileManager.default
        let support =
            (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let memoDir = support.appendingPathComponent("Trace", isDirectory: true)
            .appendingPathComponent("voice-memos", isDirectory: true)
        let memo = VoiceMemoCapture(mic: mic, outputDirectory: memoDir)

        self.modeRegistry = registry
        self.personalDictionary = dictionary
        self.historyStore = history
        self.audio = mic
        self.pasteActor = paste
        self.voiceMemo = memo
        self.asrAdapter = asr
        self.controller = DictationController(dependencies: deps)
    }
}

struct LivePipelineDependencies: PipelineDependencies {
    let modeRegistry: ModeRegistry
    let modeResolver: ModeResolver
    let personalDictionary: PersonalDictionary
    let historyStore: DictationHistoryStore?
    let audio: PipelineAudioSource
    let asr: PipelineASR
    let cleanup: PipelineCleanup
    let paste: PipelinePaste

    func now() -> TimeInterval { Date().timeIntervalSince1970 }
}

struct LiveAudioAdapter: PipelineAudioSource {
    let mic: MicCapture

    func startCapture() async throws {
        try mic.start()
    }

    func stopCapture() async {
        mic.stop()
    }

    nonisolated func buffers() -> AsyncStream<AVAudioPCMBuffer> {
        // `subscribe()`, NOT the legacy single-shot `mic.buffers`: the headless
        // `runOneCycle` path (waitForCaptureEndpoint) reuses one cached controller
        // across MCP cycles, and a single-shot stream is already exhausted by the
        // second `ask_user_dictation`. `subscribe()` returns a fresh stream per
        // call — the same reason BatchedASR subscribes for the ASR feed.
        mic.subscribe()
    }
}

/// Engine choice surfaced in Settings → ASR Engines.
///
/// The dictation pipeline
/// constructs a `BatchedASR` wrapping the corresponding `TranscriptionBackend`.
public enum DictationASREngine: String, Sendable, Hashable, Codable, CaseIterable {
    case appleSpeech
    case parakeet
    case whisperKit
    case qwen3
    case cloud

    public var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (built-in, on-device)"
        case .parakeet: return "Parakeet TDT v3 (FluidAudio, on-device)"
        case .whisperKit: return "WhisperKit (Whisper, on-device)"
        case .qwen3: return "Qwen3-ASR (on-device)"
        case .cloud: return "Cloud (bring your own key)"
        }
    }

    /// Whether this engine can emit live interim ("partial") results during
    /// capture.
    ///
    /// Apple Speech supports it via `shouldReportPartialResults`;
    /// Parakeet / WhisperKit / Qwen3 run as a single offline pass (no interim
    /// output), so the live-transcript feature is gated off for them. Cloud is
    /// provider-dependent — reporting `true` keeps the live-preview toggle
    /// available; the registry only returns a streaming transcriber for providers
    /// that actually stream (Deepgram), and the pipeline falls back to the batch
    /// path otherwise.
    public var supportsStreaming: Bool {
        switch self {
        case .appleSpeech, .cloud: return true
        case .parakeet, .whisperKit, .qwen3: return false
        }
    }

    /// `true` for engines that send audio to a network service (BAS-21).
    ///
    /// Drives
    /// the cloud-provider sub-picker + BYOK key gating in Settings; the default
    /// experience stays fully local.
    public var isCloud: Bool { self == .cloud }
}

final class BatchedASR: PipelineASR, @unchecked Sendable {
    private let backend: any TranscriptionBackend
    private let mic: MicCapture
    /// Live streaming transcriber for this engine, or nil if it's batch-only.
    ///
    /// When present and it starts successfully, its transcript IS the result —
    /// we skip the batch pass and the 16 kHz sample buffering entirely.
    private let streamer: (any StreamingTranscriber)?
    /// Called off-main with each interim transcript while streaming.
    private let onPartial: (@Sendable (String) -> Void)?
    /// Called off-main with the live mic level (0…1) for the notch VU meter (BAS-79).
    private let onLevel: (@Sendable (Double) -> Void)?
    /// The language to decode (BAS-74) — `.autoDetect` lets Whisper detect it.
    private let locale: Locale
    private var collectedSamples: [Float] = []
    private var consumeTask: Task<Void, Never>?
    private var streamingActive = false

    /// Batch engines expect 16 kHz mono Float32.
    private static let targetSampleRate: Double = 16_000

    init(
        backend: any TranscriptionBackend,
        mic: MicCapture,
        streamer: (any StreamingTranscriber)? = nil,
        locale: Locale = .current,
        onPartial: (@Sendable (String) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil
    ) {
        self.backend = backend
        self.mic = mic
        self.streamer = streamer
        self.locale = locale
        self.onPartial = onPartial
        self.onLevel = onLevel
    }

    /// Maps a 16 kHz mono chunk to a 0…1 level for the notch VU meter.
    ///
    /// Square-root
    /// curve so quiet speech still nudges the bars; tunable (BAS-79).
    private static func vuLevel(_ samples: [Float]) -> Double {
        min(1.0, Double(rms(samples)).squareRoot() * 3.0)
    }

    func prepareBackend() async throws {
        try await backend.prepare(onStatus: { _ in }, onProgress: { _ in })
    }

    func beginCycle() async throws {
        // Cancel any consume task a prior cycle left running. The happy path nils
        // this in finishCycle, but a cycle aborted via the controller's cancel()
        // (e.g. runOneCycle timing out) never calls finishCycle — without this the
        // orphaned task keeps its mic subscription and would append to
        // collectedSamples concurrently with the new cycle's task (doubled audio +
        // a data race on the non-isolated buffer).
        consumeTask?.cancel()
        consumeTask = nil
        collectedSamples.removeAll(keepingCapacity: true)
        streamingActive = false

        // Model-adaptive capture. If the engine provides a streaming transcriber
        // and it starts, feed it the mic and use its transcript as the result —
        // no batch pass, no sample buffering. Otherwise buffer 16 kHz samples for
        // a one-shot batch transcription on stop.
        if let streamer, let onPartial, await streamer.start(onPartial: onPartial) {
            streamingActive = true
            let stream = mic.subscribe()
            consumeTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self else { return }
                    self.onLevel?(Self.vuLevel(ASRAudioConvert.mono16kFloat(buffer)))
                    self.streamer?.append(buffer)
                }
            }
        } else {
            let stream = mic.subscribe()
            consumeTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self else { return }
                    let samples = ASRAudioConvert.mono16kFloat(buffer)
                    self.onLevel?(Self.vuLevel(samples))
                    self.collectedSamples.append(contentsOf: samples)
                }
            }
        }
    }

    func finishCycle() async throws -> String {
        consumeTask?.cancel()
        consumeTask = nil
        onLevel?(0)  // drop the notch VU meter when capture stops (BAS-79)

        // Streaming engine: the live transcriber already produced the transcript;
        // finish() waits for its final result so the last word is captured. No
        // batch pass.
        if streamingActive, let streamer {
            streamingActive = false
            let streamed = await streamer.finish()
            collectedSamples.removeAll(keepingCapacity: true)
            Loggers.dictation.info(
                "BatchedASR finishCycle (streaming) transcript len=\(streamed.count, privacy: .public)"
            )
            return streamed
        }

        // Batch engine: no live transcript — transcribe the whole captured
        // buffer in one pass. Brief grace period first to let any in-flight
        // buffers drain into our subscriber.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let samples = collectedSamples
        collectedSamples.removeAll(keepingCapacity: true)
        let rms = Self.rms(samples)
        Loggers.dictation.info(
            "BatchedASR finishCycle (batch) samples=\(samples.count, privacy: .public) duration=\(Double(samples.count) / Self.targetSampleRate, privacy: .public)s rms=\(rms, privacy: .public)"
        )
        guard !samples.isEmpty else { return "" }
        return try await backend.transcribe(samples, locale: locale, previousContext: nil)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

}

/// Routes the raw ASR transcript through the model router for LLM-driven
/// punctuation, capitalization, and per-mode voice (Email → formal, Slack →
/// casual, Code → no caps, etc.). Falls through to a deterministic fixer
/// (capitalize first letter, ensure trailing punctuation) if:
///   1. No `ModelRouter` is supplied (constructor option),
///   2. The router can't find a registered provider for `.dictationCleanup`, or
///   3. The provider call throws (e.g. Apple Intelligence disabled, no key).
struct RouterCleanup: PipelineCleanup {
    let router: ModelRouter?
    /// When true, skip the LLM entirely and use the deterministic fixer.
    ///
    /// Set
    /// by AppRuntimeCoordinator based on Settings → LLM Router → Deterministic.
    let deterministicOnly: Bool

    init(router: ModelRouter?, deterministicOnly: Bool = false) {
        self.router = router
        self.deterministicOnly = deterministicOnly
    }

    func clean(rawText: String, systemPrompt: String, routeOverride: LLMRoute?) async throws -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }
        if deterministicOnly {
            return Self.deterministicFix(trimmed)
        }

        if let router {
            do {
                let request = LLMRequest(
                    messages: [
                        LLMMessage(role: .system, content: Self.composeInstructions(modeRules: systemPrompt)),
                        LLMMessage(role: .user, content: trimmed),
                    ],
                    taskClass: .dictationCleanup,
                    temperature: 0.2,
                    maxTokens: max(64, trimmed.count * 2)
                )
                let response = try await router.generate(request)
                let cleaned = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    Loggers.dictation.info(
                        "Cleanup via \(response.provider, privacy: .public)/\(response.model, privacy: .public)"
                    )
                    return cleaned
                }
            } catch {
                Loggers.dictation.warning(
                    "LLM cleanup failed, falling back to deterministic fixer: \(String(describing: error), privacy: .public)"
                )
            }
        }

        return Self.deterministicFix(trimmed)
    }

    /// Wrap the per-mode rules in a strict "transform, never respond" frame.
    ///
    /// Apple's on-device model is chat-tuned, so a conversational transcript
    /// ("hello how are you") otherwise gets *answered* like a chatbot instead of
    /// cleaned. The hard rules + concrete greeting/question examples force it to
    /// treat the transcript purely as text to reformat. Applied to every mode
    /// (built-in and custom) so the guard can't be forgotten in a mode prompt.
    static func composeInstructions(modeRules: String) -> String {
        """
        You are a dictation post-processing function inside a dictation app — NOT a \
        chat assistant. The user's message is a raw speech-to-text transcript of \
        words the user just spoke and wants inserted into whatever app they are \
        typing in.

        Hard rules — never break these:
        - NEVER answer, reply to, or converse with the transcript. If it is a \
        question, greeting, or request, you do NOT respond to it — you only clean \
        up or reformat the words themselves.
        - Output ONLY the resulting text: no quotes, labels, preamble, \
        explanations, or follow-up lines.
        - Produce the result exactly once. Never repeat it.
        - Preserve the user's meaning and facts. Never invent content.

        How to transform the transcript in this context:
        \(modeRules)

        Examples (notice the question/greeting is cleaned, never answered):
        - Transcript: "hello how are you doing today" → Hello, how are you doing today?
        - Transcript: "whats the status on the deploy" → What's the status on the deploy?
        """
    }

    /// Capitalizes the first letter, ensures the string ends with a period,
    /// and trims duplicate whitespace.
    ///
    /// Used when no LLM is reachable so the
    /// pasted text still looks like English instead of raw ASR output.
    static func deterministicFix(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return raw }
        if let first = s.first, first.isLetter, first.isLowercase {
            s = s.prefix(1).uppercased() + s.dropFirst()
        }
        if let last = s.last, !".!?…\n".contains(last) {
            s += "."
        }
        return s
    }
}

struct LivePasteAdapter: PipelinePaste {
    let paste: AccessibilityPaste

    func insert(_ text: String, behavior: InsertBehavior) async throws -> PasteResult {
        try await paste.insert(text)
    }
}
