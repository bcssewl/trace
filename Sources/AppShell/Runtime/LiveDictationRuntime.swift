import AVFoundation
import AppKit
import Foundation
import MeetingModule
import SharedCore
@preconcurrency import Speech

extension Notification.Name {
    /// Posted (on any thread) when the dictation crash-recovery spool can't be
    /// created or written — recordings are temporarily NOT crash-protected.
    /// The coordinator turns this into a coalesced user-visible warning; the
    /// dictation itself deliberately continues in memory (refusing to record
    /// because the insurance file failed would be the worse harm).
    public static let traceDictationCrashProtectionLost = Notification.Name(
        "app.trace.dictation.crashProtectionLost")
}

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
        // Crash-durability spool: every capture's 16 kHz audio is appended to
        // disk as it arrives and deleted once the transcript is safely out, so
        // a crash mid-dictation can be recovered instead of losing the take.
        let spoolDirectory: URL?
        do {
            spoolDirectory = try DictationSpoolStore.defaultDirectory()
        } catch {
            spoolDirectory = nil
            Loggers.dictation.error(
                "dictation crash-spool directory unavailable — recordings will not be crash-durable: \(String(describing: error), privacy: .public)"
            )
            NotificationCenter.default.post(name: .traceDictationCrashProtectionLost, object: nil)
        }
        let asr = BatchedASR(
            backend: backend, subscribeAudio: { mic.subscribe() }, streamer: streamer,
            locale: transcriptionLanguage.locale, spoolDirectory: spoolDirectory,
            onPartial: onPartial, onLevel: onLevel)
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

    // MARK: - Crash recovery (orphaned dictation spools)

    /// Spools left behind by a crashed/force-quit session, newest first.
    ///
    /// Pure filesystem scan — callable before (or without) any runtime being
    /// built, e.g. at app launch to surface "a dictation from a previous
    /// session can be recovered".
    public nonisolated static func orphanedDictationSpools() -> [OrphanedDictationSpool] {
        guard let directory = try? DictationSpoolStore.defaultDirectory() else { return [] }
        return DictationSpoolStore.orphanedSpools(in: directory)
    }

    /// Recovers one orphaned spool: transcribes its audio through this
    /// runtime's batch ASR backend, saves the text to dictation history
    /// flagged `recovered`, copies it to the clipboard, and deletes the spool.
    public func recoverDictationSpool(_ orphan: OrphanedDictationSpool) async throws -> DictationRecord {
        let directory = try DictationSpoolStore.defaultDirectory()
        let recovery = DictationSpoolRecovery(directory: directory, historyStore: historyStore)
        let asr = asrAdapter
        return try await recovery.recover(orphan) { samples in
            try await asr.transcribeBatch(samples)
        }
    }

    /// Deletes an orphaned spool the user chose not to recover.
    public nonisolated static func discardDictationSpool(_ orphan: OrphanedDictationSpool) {
        DictationSpoolStore.discard(orphan)
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

/// Actor-isolated capture/transcription adapter between the mic and the
/// dictation controller.
///
/// Actor isolation is the data-race fix: `collectedSamples`, `consumeTask`,
/// `streamingActive`, and the crash-recovery spool used to be plain fields
/// mutated both by the consume task and by `beginCycle()`/`finishCycle()` with
/// no synchronisation. Now every mutation happens on the actor, and cycle
/// boundaries are made deterministic two ways:
///
/// - `finishCycle()` cancels the consume task and AWAITS its completion, so it
///   observes every sample of its own cycle and the task can't append after
///   the snapshot;
/// - each cycle carries a generation token; a stale task (cancelled but still
///   unwinding) that calls back in with an old generation is ignored, so it
///   can never pollute the next cycle's buffer.
actor BatchedASR: PipelineASR {
    private let backend: any TranscriptionBackend
    /// Fresh per-cycle mic stream factory (`MicCapture.subscribe` in
    /// production; hand-driven streams in tests).
    private let subscribeAudio: @Sendable () -> AsyncStream<AVAudioPCMBuffer>
    /// Live streaming transcriber for this engine, or nil if it's batch-only.
    ///
    /// When present and it starts successfully, its transcript IS the result —
    /// we skip the batch pass (the 16 kHz samples are still spooled to disk
    /// for crash recovery).
    private let streamer: (any StreamingTranscriber)?
    /// Called off-main with each interim transcript while streaming.
    private let onPartial: (@Sendable (String) -> Void)?
    /// Called off-main with the live mic level (0…1) for the notch VU meter (BAS-79).
    private let onLevel: (@Sendable (Double) -> Void)?
    /// The language to decode (BAS-74) — `.autoDetect` lets Whisper detect it.
    private let locale: Locale
    /// Where crash-recovery spools are written; nil disables spooling.
    private let spoolDirectory: URL?

    private var collectedSamples: [Float] = []
    private var consumeTask: Task<Void, Never>?
    private var streamingActive = false
    /// Cycle generation — bumped by `beginCycle`/`cancelCycle` so a stale
    /// consume task's late appends are ignored.
    private var generation: UInt64 = 0
    /// Crash-durability spool for the in-flight cycle (see
    /// `DictationAudioSpool`). Deleted on clean completion or cancel; kept on
    /// disk when transcription fails or the process dies.
    private var spool: DictationAudioSpool?
    private var spoolWriteFailureLogged = false

    /// Batch engines expect 16 kHz mono Float32.
    private static let targetSampleRate: Double = 16_000

    init(
        backend: any TranscriptionBackend,
        subscribeAudio: @escaping @Sendable () -> AsyncStream<AVAudioPCMBuffer>,
        streamer: (any StreamingTranscriber)? = nil,
        locale: Locale = .current,
        spoolDirectory: URL? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil
    ) {
        self.backend = backend
        self.subscribeAudio = subscribeAudio
        self.streamer = streamer
        self.locale = locale
        self.spoolDirectory = spoolDirectory
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
        // Retire any consume task a prior cycle left running and WAIT for it —
        // a merely-cancelled task could still be mid-append. After this await
        // no stale append can interleave with the new cycle's state.
        await retireConsumeTask()
        generation &+= 1
        let gen = generation
        collectedSamples.removeAll(keepingCapacity: true)
        streamingActive = false
        // A leftover spool here means the previous cycle was abandoned without
        // finish/cancel — in-process, so the audio was deliberately dropped.
        spool?.discard()
        spool = nil
        openSpool()

        // Model-adaptive capture. If the engine provides a streaming transcriber
        // and it starts, feed it the mic and use its transcript as the result —
        // no batch pass. Either way the 16 kHz samples are appended to the
        // crash-recovery spool as they arrive.
        if let streamer, let onPartial, await streamer.start(onPartial: onPartial) {
            streamingActive = true
            let stream = subscribeAudio()
            consumeTask = Task { [weak self, streamer, onLevel = self.onLevel] in
                for await buffer in stream {
                    guard let self else { return }
                    let samples = ASRAudioConvert.mono16kFloat(buffer)
                    onLevel?(Self.vuLevel(samples))
                    streamer.append(buffer)
                    await self.spoolOnly(samples, generation: gen)
                }
            }
        } else {
            let stream = subscribeAudio()
            consumeTask = Task { [weak self, onLevel = self.onLevel] in
                for await buffer in stream {
                    guard let self else { return }
                    let samples = ASRAudioConvert.mono16kFloat(buffer)
                    onLevel?(Self.vuLevel(samples))
                    await self.ingest(samples, generation: gen)
                }
            }
        }
    }

    func finishCycle() async throws -> String {
        // Grace period FIRST so in-flight buffers drain into the consumer (the
        // controller already stopped the mic), THEN deterministically retire
        // the task. The old order — cancel, then sleep — threw the tail away.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await retireConsumeTask()
        onLevel?(0)  // drop the notch VU meter when capture stops (BAS-79)

        // Streaming engine: the live transcriber already produced the transcript;
        // finish() waits for its final result so the last word is captured. No
        // batch pass.
        if streamingActive, let streamer {
            streamingActive = false
            let streamed = await streamer.finish()
            collectedSamples.removeAll(keepingCapacity: true)
            closeSpoolClean()
            Loggers.dictation.info(
                "BatchedASR finishCycle (streaming) transcript len=\(streamed.count, privacy: .public)"
            )
            return streamed
        }

        // Batch engine: no live transcript — transcribe the whole captured
        // buffer in one pass.
        let samples = collectedSamples
        collectedSamples.removeAll(keepingCapacity: true)
        let rms = Self.rms(samples)
        Loggers.dictation.info(
            "BatchedASR finishCycle (batch) samples=\(samples.count, privacy: .public) duration=\(Double(samples.count) / Self.targetSampleRate, privacy: .public)s rms=\(rms, privacy: .public)"
        )
        guard !samples.isEmpty else {
            closeSpoolClean()
            return ""
        }
        do {
            let text = try await backend.transcribe(samples, locale: locale, previousContext: nil)
            // Transcript safely extracted — the spool has served its purpose.
            closeSpoolClean()
            return text
        } catch {
            // Transcription failed AFTER capture: keep the audio on disk so the
            // recording is recoverable instead of gone.
            spool?.keepForRecovery()
            spool = nil
            Loggers.dictation.error(
                "BatchedASR transcription failed — audio kept for recovery: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Abandon the in-flight cycle: the user cancelled, so drop the buffered
    /// samples, retire the consumer, and DELETE the spool (a deliberate cancel
    /// is not a crash — nothing to recover).
    func cancelCycle() async {
        await retireConsumeTask()
        generation &+= 1
        onLevel?(0)
        if streamingActive, let streamer {
            streamingActive = false
            _ = await streamer.finish()
        }
        collectedSamples.removeAll(keepingCapacity: true)
        spool?.discard()
        spool = nil
    }

    /// One-shot batch transcription outside a capture cycle — the
    /// crash-recovery path runs orphaned spool audio through this.
    func transcribeBatch(_ samples: [Float]) async throws -> String {
        try await backend.transcribe(samples, locale: locale, previousContext: nil)
    }

    // MARK: - consume-task plumbing

    /// Appends a chunk to the cycle buffer + spool — actor-isolated, and
    /// generation-guarded so a stale task can't pollute the next cycle.
    private func ingest(_ samples: [Float], generation gen: UInt64) {
        guard gen == generation else { return }
        collectedSamples.append(contentsOf: samples)
        appendToSpool(samples)
    }

    /// Spool-only append for the streaming path (the live transcriber owns the
    /// transcript; the disk copy is purely crash insurance).
    private func spoolOnly(_ samples: [Float], generation gen: UInt64) {
        guard gen == generation else { return }
        appendToSpool(samples)
    }

    /// Cancels the consume task and awaits its completion, so no append can
    /// land after this returns. Suspending here releases the actor, letting
    /// the task's final in-flight `ingest` calls run before it unwinds.
    private func retireConsumeTask() async {
        guard let task = consumeTask else { return }
        consumeTask = nil
        task.cancel()
        await task.value
    }

    // MARK: - spool plumbing

    private func openSpool() {
        guard let spoolDirectory else { return }
        spoolWriteFailureLogged = false
        do {
            spool = try DictationAudioSpool(directory: spoolDirectory)
        } catch {
            spool = nil
            // Loud, but the dictation itself continues in memory — refusing to
            // record because the insurance file failed would be the worse harm.
            Loggers.dictation.error(
                "dictation crash-spool unavailable for this cycle: \(String(describing: error), privacy: .public)"
            )
            NotificationCenter.default.post(name: .traceDictationCrashProtectionLost, object: nil)
        }
    }

    private func appendToSpool(_ samples: [Float]) {
        guard let spool else { return }
        do {
            try spool.append(samples)
        } catch {
            if !spoolWriteFailureLogged {
                spoolWriteFailureLogged = true
                Loggers.dictation.error(
                    "dictation crash-spool write failed — disk copy stops here, capture continues: \(String(describing: error), privacy: .public)"
                )
                NotificationCenter.default.post(name: .traceDictationCrashProtectionLost, object: nil)
            }
        }
    }

    private func closeSpoolClean() {
        spool?.finishClean()
        spool = nil
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
