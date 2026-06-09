# Dictation worktree — coordinator integration notes

Everything in this file is wiring the dictation agent could not perform itself
because it lives in `AppRuntimeCoordinator.swift` / hotkey plumbing (forbidden
territory). All controller/runtime/HUD APIs referenced below already exist and
are additive — current coordinator code compiles unchanged; applying these
notes turns the new behaviour on.

No new `TraceError` cases are required. No `Package.swift` changes are
required. Schema v34 (`dictations.recovered`) is already registered in
`AppSchema.allMigrations` (additive line; v34–v35 are the dictation group's
reserved versions, v35 still free).

---

## 1. Launch-time crash-recovery surfacing

Dictation audio is now spooled to disk during capture
(`Application Support/Trace/dictation-spools`, raw 16 kHz Float32 PCM + JSON
sidecar) and deleted when a cycle completes. After a crash/force-quit the
spool survives; the history view (Library → Dictation) already shows a
"Recovered recordings" section with working Recover/Discard buttons, no
coordinator involvement needed.

What the coordinator should add: tell the user at launch. In the
post-bootstrap task in `AppRuntimeCoordinator.init` (next to
`recoverInterruptedFileJobs()`), add:

```swift
await self?.surfaceOrphanedDictations()
```

```swift
/// A dictation from a previous session crashed mid-recording: its audio is
/// recoverable. Point the user at Library → Dictation, where the recovery
/// affordance lives.
private func surfaceOrphanedDictations() async {
    let orphans = LiveDictationRuntime.orphanedDictationSpools()
    guard !orphans.isEmpty else { return }
    let count = orphans.count
    Loggers.dictation.warning(
        "found \(count, privacy: .public) recoverable dictation spool(s) from a previous session")
    environment.notices.post(
        severity: .info,
        title: count == 1 ? "Unsaved dictation found" : "Unsaved dictations found",
        message: count == 1
            ? "A dictation from a previous session didn't finish. Open Library → Dictation to recover or discard it."
            : "\(count) dictations from a previous session didn't finish. Open Library → Dictation to recover or discard them.",
        coalescingKey: "dictation.spool.recovery"
    )
    // Optional notch nudge as well:
    // notchHUD?.showCompact(timer: "0:00", kind: .recoveryAvailable(count))
    // …then hide() after ~3 s.
}
```

Alternative for a coordinator-driven recovery (e.g. an "auto-recover at
launch" setting later): `runtime.recoverDictationSpool(_:)` transcribes via
the runtime's batch ASR backend, writes the history record
(`recovered == true`), copies the text to the clipboard, and deletes the
spool. `LiveDictationRuntime.discardDictationSpool(_:)` deletes one.

## 2. `runStartDictation` — epoch guard + honest start errors

Two bugs fixed here: (a) a stop while the runtime is still being built leaves
a zombie recording with no HUD; (b) the `catch` around `startCapture` only
logs, leaving "listening" on screen after a failed start.

Add one property near `dictationTriggerMonitor`:

```swift
/// Bumped on every dictation start AND stop. A start task that wakes up from
/// an await (model download, runtime build) with a stale generation aborts —
/// the user already said stop.
private var dictationStartGeneration: UInt64 = 0
```

Replace `runStartDictation()` with:

```swift
private func runStartDictation() {
    let firstBuild = (dictationRuntime == nil)
    dictationStartGeneration &+= 1
    let myGeneration = dictationStartGeneration
    environment.state.activeCapture.beginDictation(sessionId: "dictation-\(Int(Date().timeIntervalSince1970))")
    installEnterInterceptorIfEnabled()
    installEscapeCancelInterceptor()
    notchHUD?.showCompact(timer: "0:00", kind: firstBuild ? .preparing : .listening)
    Loggers.dictation.info("AppCommands.startDictation invoked (firstBuild=\(firstBuild, privacy: .public))")
    Task { [weak self] in
        guard let self else { return }
        guard await self.awaitDictationModelIfNeeded() else {
            Loggers.dictation.error("startDictation: speech model download failed")
            self.notchHUD?.setKind(.downloadFailed)
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            self.abortDictationStartup()
            return
        }
        guard let runtime = await self.ensureDictationRuntime() else {
            Loggers.dictation.error("startDictation: runtime unavailable")
            self.notchHUD?.setKind(.unavailable)
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            self.abortDictationStartup()
            return
        }
        // Stop-before-ready: if the user pressed stop while the model/runtime
        // was still coming up, this start is stale — abort it instead of
        // zombie-recording with no HUD.
        guard self.dictationStartGeneration == myGeneration else {
            Loggers.dictation.info("startDictation: superseded while preparing — aborted")
            return  // runStopDictation already tore the chrome down
        }
        if firstBuild {
            self.notchHUD?.state.startedAt = Date()
            self.notchHUD?.setKind(.listening)
        }
        // If the previous cycle's tail is still finishing, startCapture CHAINS
        // (event-driven, starts the instant the tail completes). Be honest in
        // the HUD while that happens.
        let pre = await runtime.controller.currentState()
        if pre != .idle && !pre.isTerminal && pre != .recording {
            self.notchHUD?.setKind(.stillFinishing)
        }
        do {
            // Mint the controller-side epoch right before starting; a stop
            // arriving between here and recording bumps it and the start
            // unwinds itself (audio + ASR cycle + spool all cleaned up).
            let token = await runtime.controller.currentEpoch()
            try await runtime.controller.startCapture(mode: .toggle, epoch: token)
            self.notchHUD?.setKind(.listening)
        } catch let startError as DictationStartError {
            switch startError {
            case .cancelledBeforeStart:
                // The user already said stop — quiet exit, no scary banner.
                Loggers.dictation.info("startDictation: cancelled before start")
                self.abortDictationStartup()
            case .busyFinishingPrevious:
                self.notchHUD?.setKind(.stillFinishing)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.abortDictationStartup()
            }
        } catch {
            // NEVER leave "listening" showing after a failed start.
            Loggers.dictation.error(
                "startCapture failed: \(String(describing: error), privacy: .public)")
            let kind: NotchKind
            switch error as? TraceError {
            case .permissionDenied(let permission) where permission == .microphone:
                kind = .micUnavailable
            case .audioDeviceMissing, .audioCaptureFailed:
                kind = .micUnavailable
            case .asrModelMissing:
                kind = .modelMissing
            default:
                kind = .failed
            }
            self.notchHUD?.setKind(kind)
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            self.abortDictationStartup()
        }
    }
}
```

(`case .audioDeviceMissing, .audioCaptureFailed` matches the optional pattern
`Optional<TraceError>`; if the compiler complains, switch on
`error as? TraceError` via `if let trace = error as? TraceError { switch trace
{ … } }` instead — same mapping.)

## 3. `runStopDictation` — generation bump, zombie kill, secure-field HUD

Replace the body's opening and result handling:

```swift
private func runStopDictation(submitAfterInsert: Bool = false) {
    teardownEnterInterceptor()
    teardownEscapeCancelInterceptor()
    dictationStartGeneration &+= 1  // kill any start still preparing
    environment.state.activeCapture.end()
    let streamedLive =
        environment.state.dictationShowLivePartials
        && environment.state.dictationASREngine.supportsStreaming
    notchHUD?.setKind(streamedLive ? .cleaning : .transcribing)
    Loggers.dictation.info("AppCommands.stopDictation invoked")
    Task { [weak self] in
        guard let self else { return }
        guard let runtime = self.dictationRuntime else {
            self.notchHUD?.hide()
            return
        }
        // Invalidate any startCapture still arming (epoch), so a stop that
        // lands mid-arming cancels that pending cycle rather than letting it
        // reach .recording with no HUD.
        await runtime.controller.invalidatePendingStarts()
        do {
            let result = try await runtime.controller.stopCapture()
            if let result {
                Loggers.dictation.info(
                    "stopCapture finalized rawLen=\(result.rawText.count, privacy: .public) cleanedLen=\(result.cleanedText.count, privacy: .public) pasted=\(result.pasted, privacy: .public) strategy=\(String(describing: result.pasteStrategy), privacy: .public)"
                )
                if result.cleanedText.isEmpty {
                    self.notchHUD?.setKind(.noAudio)
                } else if result.pasteStrategy == .secureFieldRefused {
                    // Password field: the text was NOT inserted and was NOT
                    // put on the clipboard. Saying "Copied" here would be a
                    // lie — and a security smell.
                    self.notchHUD?.setKind(.secureField)
                } else if !result.pasted {
                    self.notchHUD?.setKind(.copied)
                } else {
                    self.notchHUD?.setKind(.inserted)
                    if submitAfterInsert {
                        await self.submitReturnAfterInsert()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            } else {
                // stopCapture was a no-op: nothing was recording. If a cycle
                // is still ARMING (stop raced the start), cancel it so it
                // can't become a zombie recording.
                let state = await runtime.controller.currentState()
                if !state.isTerminal && state != .idle {
                    await runtime.controller.cancel()
                }
            }
        } catch {
            Loggers.dictation.error(
                "stopCapture failed: \(String(describing: error), privacy: .public)")
            self.notchHUD?.setKind(.failed)
            try? await Task.sleep(nanoseconds: 1_400_000_000)
        }
        self.notchHUD?.hide()
    }
}
```

## 4. Return-to-send — verified/adaptive submit

`AccessibilityPaste` now owns the post-insert Return: it verifies via AX that
the inserted text is actually present before submitting (refusing if it never
landed), and scales the delay for slow web/Electron targets instead of a fixed
70 ms. Replace `submitReturnAfterInsert()` with:

```swift
/// Submit via the paste actor: it verifies the inserted text is present
/// (AX path) or scales the settle delay for slow web/Electron targets, and
/// refuses outright when nothing was actually inserted.
private func submitReturnAfterInsert() async {
    guard let runtime = dictationRuntime else { return }
    let sent = await runtime.pasteActor.submitReturn()
    Loggers.dictation.info("Return-to-send: submitted=\(sent, privacy: .public)")
}
```

(The old direct `CGEventKeySynthesizer().send(.returnKey)` import/usage can go.)

## 5. Esc-to-cancel

`EscapeKeyInterceptor` (SharedCore, Bridges) swallows a bare Escape while
dictation records — same active-tap mechanics and Accessibility-trust
behaviour as `EnterKeyInterceptor`. Wire it exactly like the Return
interceptor:

```swift
private var escapeCancelInterceptor: EscapeKeyInterceptor?

/// Armed for every dictation: Esc cancels the recording outright (audio +
/// crash-spool discarded, nothing inserted), and the Escape never reaches the
/// focused app where it could close a dialog.
private func installEscapeCancelInterceptor() {
    teardownEscapeCancelInterceptor()
    let interceptor = EscapeKeyInterceptor { [weak self] in
        self?.runCancelDictation()
    }
    switch interceptor.start() {
    case .started:
        escapeCancelInterceptor = interceptor
    case .missingPermission:
        Loggers.dictation.info("Esc-to-cancel: Accessibility not granted; Esc left alone this session")
    case .failed:
        Loggers.dictation.error("Esc-to-cancel: event tap creation failed")
    }
}

private func teardownEscapeCancelInterceptor() {
    escapeCancelInterceptor?.stop()
    escapeCancelInterceptor = nil
}

/// Esc pressed while dictating: bin the recording. Controller-side this
/// stops audio, discards buffered samples AND the crash-recovery spool, and
/// invalidates any start still arming.
private func runCancelDictation() {
    teardownEnterInterceptor()
    teardownEscapeCancelInterceptor()
    dictationStartGeneration &+= 1
    environment.state.activeCapture.end()
    Loggers.dictation.info("dictation cancelled via Esc")
    Task { [weak self] in
        guard let self else { return }
        if let runtime = self.dictationRuntime {
            await runtime.controller.cancel()  // also bumps the controller epoch
        }
        self.notchHUD?.setKind(.cancelled)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        self.notchHUD?.hide()
    }
}
```

Also call `teardownEscapeCancelInterceptor()` inside `abortDictationStartup()`
(next to `teardownEnterInterceptor()`).

## 6. Settings — invalid mode patterns (ModeDiagnostics)

A custom mode with an invalid `bundleIDRegex`/`urlRegex` no longer breaks
resolution — it is skipped, error-logged, and recorded in
`ModeDiagnostics.shared`. Settings → Dictation Modes should display it next to
the offending mode so the user knows why their mode never matches:

- `ModeDiagnostics.shared.currentIssues()` → `[ModePatternIssue]`
  (`modeID`, `modeName`, `field` (.bundleIDRegex/.urlRegex), `pattern`,
  `message`).
- Refresh on the `ModeDiagnostics.issuesDidChange` notification.
- Suggested UI: a warning glyph + the `message` under the regex text field in
  `DictationModesSettingsView` for any mode whose id appears in the issues.
  (DictationModesSettingsView is Settings territory — not modified by this
  worktree.)

Issues self-clear when the pattern compiles again (the user fixed it).

## 7. New/changed public API summary (all additive)

- `DictationController.startCapture(mode:epoch:)` — `epoch` defaults to nil
  (old call sites unchanged). Busy tail now CHAINS event-driven (was an 8 s
  poll + silent discard) and throws `DictationStartError.busyFinishingPrevious`
  after a 20 s ceiling.
- `DictationController.currentEpoch()` / `invalidatePendingStarts()`.
- `DictationStartError` (`cancelledBeforeStart`, `busyFinishingPrevious`).
- `DictationController.cancel()` now also discards the ASR cycle + spool and
  bumps the epoch.
- `PipelineASR.cancelCycle()` — new requirement with a default no-op.
- `PasteResult.secureFieldRefused` + `PasteResult.didInsert`.
- `AccessibilityPaste.submitReturn()`; `AccessibilityPaste.init` gained
  defaulted knobs (`slowRestoreDelayNanos`, `returnDelayNanos`,
  `slowReturnDelayNanos`, `trustCheck`).
- `AXTextInserting` protocol reshaped (`attemptInsert` → `AXInsertOutcome`,
  `verifyInsertedText`) — conformers were all in dictation territory.
- `NotchKind`: `.micUnavailable`, `.modelMissing`, `.secureField`,
  `.cancelled`, `.stillFinishing`, `.recoveryAvailable(Int)`.
- `EscapeKeyInterceptor`.
- `DictationAudioSpool` / `DictationSpoolStore` / `DictationSpoolRecovery` /
  `OrphanedDictationSpool` (SharedCore).
- `LiveDictationRuntime.orphanedDictationSpools()` (static) /
  `recoverDictationSpool(_:)` / `discardDictationSpool(_:)` (static).
- `DictationRecord.recovered` (defaulted init param; decode tolerates old
  JSON), `dictations.recovered` column via `DictationSchemaV34` (v34,
  registered in `AppSchema`).
- `ModeRegexCache`, `ModeDiagnostics`, `ModePatternIssue`;
  `ModeResolver.init` gained a defaulted `diagnostics:` param.
- `CaptureStateMachine.waitForQuiescence(timeout:)`.
- `BatchedASR` is now an actor; its init takes `subscribeAudio:` (stream
  factory) instead of `mic:` and an optional `spoolDirectory:` —
  internal type, only constructed by `LiveDictationRuntime`.

## 8. Disk-use bound for spools

`DictationSpoolStore.enforceCap` prunes orphans older than 30 days, then
oldest-first beyond 750 MB total. It runs on every recovery scan
(history view / `DictationSpoolRecovery.orphans()`), and every prune writes a
LOUD history note ("A crashed dictation recording from … was removed without
being recovered…", flagged `recovered`) — never a silent deletion. No
coordinator action required.
