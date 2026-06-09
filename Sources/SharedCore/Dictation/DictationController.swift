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
/// deltas, discards the crash-recovery spool, and skips paste.
///
/// Start epochs: a stop/cancel that lands while a start is still in flight
/// (model downloading, runtime building, mode resolving) must kill that
/// pending start instead of letting it become a zombie recording. Callers mint
/// a token with `currentEpoch()`/`invalidatePendingStarts()` and pass it to
/// `startCapture(mode:epoch:)`; any stale token aborts with
/// `DictationStartError.cancelledBeforeStart`.
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
    /// Start-intent epoch. Bumped by `invalidatePendingStarts()` and `cancel()`
    /// so a `startCapture(mode:epoch:)` carrying a stale token aborts instead
    /// of zombie-recording after the user already said stop.
    private var startEpoch: UInt64 = 0
    /// Ceiling on how long a queued start will wait for the previous cycle's
    /// tail (finalising → cleaning → pasting) before failing loudly.
    private static let chainWaitCeiling: Duration = .seconds(20)

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

    // MARK: - Start epochs

    /// The current start-intent epoch.
    ///
    /// Mint a token with this before kicking
    /// off the (possibly slow) path to `startCapture`, then pass it as the
    /// `epoch:` argument — a stop/cancel in between bumps the epoch and the
    /// stale start aborts instead of zombie-recording.
    public func currentEpoch() -> UInt64 {
        startEpoch
    }

    /// Invalidates every start currently in flight (or queued behind a
    /// previous cycle's tail): any `startCapture(mode:epoch:)` holding an
    /// older token aborts with `DictationStartError.cancelledBeforeStart`.
    ///
    /// Returns the new epoch, usable as the token for a subsequent start.
    @discardableResult
    public func invalidatePendingStarts() -> UInt64 {
        startEpoch &+= 1
        return startEpoch
    }

    /// Starts a capture cycle.
    ///
    /// Caller selects push-to-talk or toggle. The
    /// controller resolves the mode from the frontmost-app provider and kicks
    /// off audio + ASR streaming. The call returns immediately; callers
    /// observe the state machine and `runOneCycle(_:)` for the final result.
    ///
    /// If the previous cycle's tail (finalising → cleaning → pasting) is still
    /// running, the new start CHAINS: it suspends — event-driven, no polling —
    /// and begins the instant the tail completes. If the tail outlives a
    /// generous ceiling the start fails loudly with
    /// `DictationStartError.busyFinishingPrevious` (never a silent discard).
    ///
    /// `epoch` is the optional start-intent token (see `currentEpoch()`); a
    /// stale token aborts with `DictationStartError.cancelledBeforeStart`.
    public func startCapture(mode: CaptureMode, epoch: UInt64? = nil) async throws {
        let myEpoch = epoch ?? startEpoch
        guard myEpoch == startEpoch else { throw DictationStartError.cancelledBeforeStart }

        var current = await stateMachine.state
        if current != .idle {
            // A previous dictation's tail may still be running when the user
            // starts the next one — especially with LLM cleanup, which takes
            // seconds. Chain onto it rather than dropping the new dictation.
            // (An active .recording is still rejected — the toggle stops it,
            // it doesn't start a second capture.)
            if !current.isTerminal, current != .recording {
                guard let settled = await stateMachine.waitForQuiescence(timeout: Self.chainWaitCeiling)
                else {
                    Loggers.dictation.error(
                        "startCapture: previous cycle still finishing after the chain ceiling — failing loudly"
                    )
                    throw DictationStartError.busyFinishingPrevious
                }
                current = settled
            }
            // A stop/cancel may have arrived while we were chained.
            guard myEpoch == startEpoch else { throw DictationStartError.cancelledBeforeStart }
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
            try checkEpochStillCurrent(myEpoch)
            try await dependencies.asr.beginCycle()
            try checkEpochStillCurrent(myEpoch)
            try await dependencies.audio.startCapture()
            try checkEpochStillCurrent(myEpoch)
            try await stateMachine.transition(to: .recording)
            Loggers.dictation.info(
                "capture started mode=\(self.resolvedMode?.name ?? "?", privacy: .public) ptt=\(mode == .pushToTalk, privacy: .public)"
            )
        } catch {
            await dependencies.audio.stopCapture()
            await dependencies.asr.cancelCycle()
            if error is DictationStartError {
                // A cancel raced the arming sequence. `cancel()` usually drove
                // the machine to .cancelled already; if not, do it here. Either
                // way this is a cancellation, not a failure.
                try? await stateMachine.transition(to: .cancelled)
                throw error
            }
            try? await stateMachine.transition(
                to: .failed(reason: failureReason(for: error, fallback: .audioCaptureFailed))
            )
            throw error
        }
    }

    /// Throws `DictationStartError.cancelledBeforeStart` when a stop/cancel
    /// bumped the epoch while the arming sequence was suspended at an await.
    private func checkEpochStillCurrent(_ epoch: UInt64) throws {
        guard epoch == startEpoch else { throw DictationStartError.cancelledBeforeStart }
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
            pasted = outcome.didInsert
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

    /// Cancels the current cycle (Esc, hotkey abort, runOneCycle timeout).
    ///
    /// Stops audio, tells the ASR adapter to abandon its cycle — dropping
    /// buffered samples AND discarding the crash-recovery spool, since the
    /// user deliberately binned this recording — and bumps the start epoch so
    /// any start still in flight aborts too. No-op if already terminal.
    public func cancel() async {
        startEpoch &+= 1
        let current = await stateMachine.state
        guard !current.isTerminal else { return }
        await dependencies.audio.stopCapture()
        await dependencies.asr.cancelCycle()
        try? await stateMachine.transition(to: .cancelled)
        Loggers.dictation.info("dictation cancelled from state \(String(describing: current), privacy: .public)")
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

/// Honest, matchable outcomes for a `startCapture` that never became a
/// recording. Callers surface BOTH distinctly in the HUD — neither may be
/// silently swallowed.
public enum DictationStartError: Error, Sendable, Equatable {
    /// A stop/cancel invalidated this start's epoch before (or while) it was
    /// arming — the user changed their mind; show nothing or "Cancelled",
    /// never "listening".
    case cancelledBeforeStart
    /// The previous dictation's tail (transcribe → clean → paste) was still
    /// running when the chain-wait ceiling expired. Surface "Still finishing
    /// the previous dictation" — never silently drop the new one.
    case busyFinishingPrevious
}
