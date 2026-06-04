@preconcurrency import AVFoundation
import Foundation

/// Top-level orchestrator for a single dictation cycle.
///
/// Owns the `CaptureStateMachine` and drives the pipeline:
///
///     idle → arming (resolve mode)
///          → recording (mic capture + streaming ASR)
///          → finalizing (drain ASR)
///          → cleaning (personal dictionary, then LLM cleanup)
///          → pasting (Accessibility insert, fallback to clipboard)
///          → done
///
/// Both push-to-talk and toggle modes funnel through the same machine. The
/// distinction is which side issues `stopCapture()`: PTT does so on hotkey-up;
/// toggle mode stops when VAD emits `.speechEnd`. The headless `runOneCycle`
/// path detects that endpoint itself (see `waitForCaptureEndpoint`); an
/// interactive caller can instead drive `stopCapture()` from its own VAD.
///
/// Cancellation: any non-terminal state can transition to `cancelled` via
/// `cancel()`. The controller drops audio capture, swallows any pending ASR
/// deltas, and skips paste.
public actor DictationController {
    public enum CaptureMode: Sendable, Hashable, Codable {
        /// Recording stops when the caller invokes `stopCapture()`.
        case pushToTalk
        /// Recording stops when the caller invokes `stopCapture()` OR when VAD
        /// signals end-of-speech — detected by `waitForCaptureEndpoint` on the
        /// `runOneCycle` path, or driven by an interactive caller's own VAD.
        case toggle
    }

    public let stateMachine: CaptureStateMachine
    public let dependencies: any PipelineDependencies

    private var currentMode: CaptureMode = .pushToTalk
    private var resolvedMode: Mode?
    private var resolvedBundleID: String?
    private var captureTask: Task<String, Error>?
    private var pendingTranscriptStream: AsyncStream<ASRDelta>?
    private var startedAt: TimeInterval = 0
    private var idForCycle: String = ""

    public init(
        dependencies: any PipelineDependencies,
        stateMachine: CaptureStateMachine = CaptureStateMachine()
    ) {
        self.dependencies = dependencies
        self.stateMachine = stateMachine
    }

    public func currentState() async -> CaptureState {
        await stateMachine.state
    }

    /// Starts a capture cycle.
    ///
    /// Caller selects push-to-talk or toggle. The
    /// controller resolves the mode from the frontmost-app provider and kicks
    /// off audio + ASR streaming. The call returns immediately; callers
    /// observe the state machine and `runOneCycle(_:)` for the final result.
    public func startCapture(mode: CaptureMode) async throws {
        var current = await stateMachine.state
        if current != .idle {
            // A previous dictation's tail (finalizing → cleaning → pasting) may
            // still be running when the user starts the next one — especially
            // with LLM cleanup, which takes seconds. Rather than DROP the new
            // dictation, wait briefly for that cycle to finish, then proceed.
            // (An active .recording is still rejected — the toggle stops it, it
            // doesn't start a second capture.)
            if !current.isTerminal, current != .recording {
                let deadline = dependencies.now() + 8.0
                while current != .idle, !current.isTerminal, dependencies.now() < deadline {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    current = await stateMachine.state
                }
            }
            if current.isTerminal {
                try await stateMachine.resetToIdle()
            } else if current != .idle {
                throw TraceError.configInvalid(
                    field: "DictationController",
                    reason: "startCapture() while not idle; current=\(current)"
                )
            }
        }
        try await stateMachine.transition(to: .arming)
        currentMode = mode
        startedAt = dependencies.now()
        idForCycle = DictationRecord.newID(at: Date(timeIntervalSince1970: startedAt))

        do {
            resolvedMode = try await dependencies.modeResolver.resolveCurrent()
            try await dependencies.asr.beginCycle()
            try await dependencies.audio.startCapture()
            try await stateMachine.transition(to: .recording)
            Loggers.dictation.info(
                "capture started mode=\(self.resolvedMode?.name ?? "?", privacy: .public) ptt=\(mode == .pushToTalk, privacy: .public)"
            )
        } catch {
            await dependencies.audio.stopCapture()
            try? await stateMachine.transition(
                to: .failed(reason: failureReason(for: error, fallback: .audioCaptureFailed))
            )
            throw error
        }
    }

    /// Issued by the hotkey-up handler (PTT) or by the VAD endpoint
    /// (toggle).
    ///
    /// Drains audio + ASR and runs the cleanup → paste tail.
    public func stopCapture() async throws -> PipelineResult? {
        let current = await stateMachine.state
        guard current == .recording else {
            // No-op if we're already past the recording stage or before it.
            return nil
        }
        guard let mode = resolvedMode else {
            try await stateMachine.transition(to: .failed(reason: .unexpected))
            throw TraceError.configInvalid(
                field: "DictationController",
                reason: "stopCapture without resolved mode"
            )
        }

        try await stateMachine.transition(to: .finalizing)
        await dependencies.audio.stopCapture()

        let rawText: String
        do {
            rawText = try await dependencies.asr.finishCycle()
        } catch {
            try? await stateMachine.transition(to: .failed(reason: .asrFailed))
            await persistFailedRecord(mode: mode, rawText: "", cleanedText: "", durationMs: durationMs())
            throw error
        }

        let (dictionaryApplied, _) = try await dependencies.personalDictionary.apply(rawText)

        try await stateMachine.transition(to: .cleaning)
        var cleanedText: String
        do {
            cleanedText = try await dependencies.cleanup.clean(
                rawText: dictionaryApplied,
                systemPrompt: mode.systemPrompt,
                routeOverride: mode.modelRouteOverride
            )
        } catch {
            try? await stateMachine.transition(to: .failed(reason: .cleanupFailed))
            await persistFailedRecord(
                mode: mode,
                rawText: rawText,
                cleanedText: dictionaryApplied,
                durationMs: durationMs()
            )
            throw error
        }
        // Strip a stray leading "." (or other leading punctuation) the ASR prepends
        // on a slow/quiet start — ". I think…" → "I think…" — which cleanup leaves.
        cleanedText = Self.trimmedLeadingPunctuation(cleanedText)

        try await stateMachine.transition(to: .pasting)
        var pasteResult: PasteResult?
        var pasted = false
        do {
            let outcome = try await dependencies.paste.insert(cleanedText, behavior: mode.insertBehavior)
            pasteResult = outcome
            pasted = outcome != .copiedOnly
        } catch {
            try? await stateMachine.transition(to: .failed(reason: .pasteFailed))
            await persistFailedRecord(
                mode: mode,
                rawText: rawText,
                cleanedText: cleanedText,
                durationMs: durationMs()
            )
            throw error
        }

        try await stateMachine.transition(to: .done)

        let result = PipelineResult(
            id: idForCycle,
            modeName: mode.name,
            bundleID: resolvedBundleID,
            rawText: rawText,
            cleanedText: cleanedText,
            pasted: pasted,
            pasteStrategy: pasteResult,
            durationMs: durationMs(),
            startedAt: startedAt
        )
        await persistResult(result)
        return result
    }

    /// Convenience that runs a complete cycle synchronously — start, then
    /// stop, then return the assembled result.
    ///
    /// Used by the MCP
    /// `ask_user_dictation` path that needs to block until the user finishes
    /// dictating.
    public func runOneCycle(
        mode: CaptureMode = .toggle,
        timeout: Duration = .seconds(120)
    ) async throws -> PipelineResult {
        try await startCapture(mode: mode)
        let reachedEndpoint = await waitForCaptureEndpoint(timeout: timeout)
        guard reachedEndpoint else {
            await cancel()
            Loggers.dictation.info("runOneCycle timed out waiting for speech — cancelled")
            throw CancellationError()
        }
        guard let result = try await stopCapture() else {
            throw TraceError.configInvalid(
                field: "DictationController",
                reason: "runOneCycle produced no result (cancelled?)"
            )
        }
        return result
    }

    /// Holds an in-progress capture open until the speaker finishes.
    ///
    /// The cycle
    /// ends on the first of: a VAD end-of-speech endpoint over the live mic feed
    /// (toggle / headless "Voice-for-Agents" dictation has no hotkey-up to stop
    /// it), the mic stream closing, or the `timeout` ceiling. Returns `true`
    /// when an endpoint or stream-end was observed, `false` when the timeout
    /// fired first (the caller cancels + surfaces that as a cancellation).
    ///
    /// The VAD runs in a child task that taps `audio.buffers()` directly, so the
    /// raw `AVAudioPCMBuffer`s never cross onto this actor — mirroring how the
    /// streaming ASR owns its own audio subscription.
    private func waitForCaptureEndpoint(timeout: Duration) async -> Bool {
        let audio = dependencies.audio
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let vad = VADManager()
                var elapsed: TimeInterval = 0
                for await buffer in audio.buffers() {
                    // Advance by each buffer's real duration (as the meeting VAD
                    // tap does) instead of assuming a fixed buffer size. VADManager
                    // endpoints on silence-frame count, so the timestamp only
                    // labels the emitted event — but deriving it keeps this robust
                    // if the mic's buffer size ever changes.
                    elapsed += Double(buffer.frameLength) / buffer.format.sampleRate
                    if case .speechEnd = await vad.ingest(buffer, frameTimestamp: elapsed) { return true }
                }
                return true  // mic stream ended → finalize what was captured
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false  // timeout ceiling
            }
            let reached = await group.next() ?? true
            group.cancelAll()
            return reached
        }
    }

    /// Cancels the current cycle.
    ///
    /// No-op if already terminal.
    public func cancel() async {
        let current = await stateMachine.state
        guard !current.isTerminal else { return }
        await dependencies.audio.stopCapture()
        try? await stateMachine.transition(to: .cancelled)
    }

    /// Records the bundle ID resolved before mode lookup.
    ///
    /// Caller invokes this
    /// from a NSWorkspace front-most-app hook on hotkey-down so the controller
    /// can attribute the cycle to the right target app for history + paste.
    public func setResolvedBundleID(_ bundleID: String?) {
        resolvedBundleID = bundleID
    }

    private func durationMs() -> Int {
        Int(max(0, (dependencies.now() - startedAt) * 1_000))
    }

    private func failureReason(
        for error: Error, fallback: CaptureState.FailureReason
    )
        -> CaptureState
        .FailureReason
    {
        guard let trace = error as? TraceError else { return fallback }
        switch trace {
        case .permissionDenied: return .permissionMissing
        case .audioCaptureFailed, .audioDeviceMissing, .audioFormatUnsupported: return .audioCaptureFailed
        case .asrModelMissing, .asrInferenceFailed, .diarizationFailed: return .asrFailed
        case .modelProviderFailed, .modelRouteUnresolved: return .cleanupFailed
        case .storageFailed, .migrationFailed: return .storageFailed
        case .networkFailed: return .cleanupFailed
        case .configInvalid: return .unexpected
        }
    }

    private func persistResult(_ result: PipelineResult) async {
        guard let store = dependencies.historyStore else { return }
        let record = DictationRecord(
            id: result.id,
            projectID: nil,
            modeName: result.modeName,
            bundleID: result.bundleID,
            rawText: result.rawText,
            cleanedText: result.cleanedText,
            inserted: result.pasted,
            durationMs: result.durationMs,
            startedAt: result.startedAt
        )
        do {
            try await store.insert(record)
        } catch {
            Loggers.dictation.error(
                "history persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistFailedRecord(mode: Mode, rawText: String, cleanedText: String, durationMs: Int) async {
        guard let store = dependencies.historyStore else { return }
        let record = DictationRecord(
            id: idForCycle,
            projectID: nil,
            modeName: mode.name,
            bundleID: resolvedBundleID,
            rawText: rawText,
            cleanedText: cleanedText,
            inserted: false,
            durationMs: durationMs,
            startedAt: startedAt
        )
        try? await store.insert(record)
    }

    /// Drops leading whitespace + stray leading punctuation (a bare "." the ASR
    /// prepends on a slow/quiet start).
    ///
    /// Keeps legitimate openers (quotes, brackets,
    /// inverted Spanish marks) so real sentences aren't altered.
    static func trimmedLeadingPunctuation(_ text: String) -> String {
        let keepers: Set<Character> = ["\"", "'", "(", "[", "{", "¿", "¡", "“", "‘"]
        var t = Substring(text)
        while let first = t.first, first.isWhitespace || (first.isPunctuation && !keepers.contains(first)) {
            t = t.dropFirst()
        }
        return String(t)
    }
}
