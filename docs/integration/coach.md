# Coach — integration notes for the coordinator pass

All CoachModule / CoachOverlayController changes are **additive and source-compatible**:
the app builds and behaves as before without any coordinator edits. The items below
wire up the new behaviour. File references are to `Sources/AppShell/App/AppRuntimeCoordinator.swift`
(forbidden territory for the coach agent) unless noted.

---

## 1. Health events → overlay banner (top priority)

`CoachOrchestrator` now emits typed health events. Emission is **edge-triggered per
stage** (one `stageUnavailable` per outage, one `stageRecovered` per recovery — never
one per utterance), so the subscriber needs no rate limiting of its own.

```swift
public enum CoachPipelineStage { case embedding, classifier, router }
public enum CoachHealthEvent {
    case stageUnavailable(stage: CoachPipelineStage, reason: String)
    case stageRecovered(stage: CoachPipelineStage)
    case cueSkipped(totalSkippedThisMeeting: Int)
}
// On CoachOrchestrator (actor):
public func healthEvents() -> AsyncStream<CoachHealthEvent>
```

`CoachOverlayController` gained a single entry point that drives the banner AND the
skipped-cues counter:

```swift
public func applyHealthEvent(_ event: CoachHealthEvent)   // forward every event here
public func prepareForNewMeeting()                        // reset banner/counters/dismissal
```

**Wiring** — in `ensureCoachOrchestrator()` (line ~1856), right after
`self.coachOrchestrator = orchestrator`, add a long-lived subscription (the
orchestrator is cached across meetings, so subscribe once at creation; store the task
in a new `private var coachHealthTask: Task<Void, Never>?` property and cancel it
wherever `coachOrchestrator` would be torn down):

```swift
coachHealthTask?.cancel()
coachHealthTask = Task { [weak self] in
    let stream = await orchestrator.healthEvents()
    for await event in stream {
        guard let self else { break }
        self.coachOverlay?.applyHealthEvent(event)
        if case .stageUnavailable(let stage, let reason) = event {
            Loggers.bridges.error(
                "Coach stage unavailable: \(stage.rawValue, privacy: .public) — \(reason, privacy: .public)")
        }
    }
}
```

**And** in `startCoach(runtime:projectName:config:)` (line ~1949), add one call before
`minimizeToPill()` so each meeting starts with a clean banner / skip counter /
dismissal state:

```swift
coachOverlay?.prepareForNewMeeting()
```

What the user sees (all British English, all defined + unit-tested in
`Sources/CoachModule/CoachHealth.swift`):

- classifier/router dead → banner **“Coach paused — model unavailable. Check Settings → Models.”**
- embedding dead (pipeline still degrades gracefully to no-RAG, as before) →
  **“Coach can't search your documents — cues fall back to general help. Check Settings → Models.”**
- recovery → banner clears automatically.
- banner is dismissible; a dismissed banner stays hidden while the failing-stage set
  is unchanged and reappears when the situation changes. The collapsed pill swaps its
  pulsing dot for an amber warning triangle while a problem is active.

The existing `catch` at line ~1984 (`Loggers.bridges.debug("Coach ingest failed…")`)
can stay — the failure is no longer invisible because the health event has already
driven the banner before `ingest` rethrows.

**TraceError:** no new cases needed; events carry the underlying error description as
a `String`.

## 2. Concurrency cap — switch the auto loop to `enqueue`

New on `CoachOrchestrator`:

```swift
public func enqueue(utterance: CoachUtterance, windowText: String? = nil) async throws -> PipelineResult?
public private(set) var skippedCueCount: Int     // per-meeting, reset by beginMeeting()
public var inFlightIngestCount: Int              // diagnostics
public var hasQueuedCue: Bool                    // diagnostics
```

Policy (implemented + tested in CoachModule): max **2** concurrent auto pipelines; when
saturated the newest utterance waits in a single “next” slot and **supersedes** whatever
was already waiting (latest-wins — fresher context beats a backlog for real-time help).
A superseded call returns `nil`, increments `skippedCueCount`, and emits
`.cueSkipped(total:)` — which `applyHealthEvent` renders as “N cues skipped under load”
in the expanded overlay. Manual (`userRequested`) utterances bypass the cap entirely and
are never superseded. `ingest` itself is unchanged (unbounded), so nothing breaks if
this rewiring is skipped.

**Wiring** — in the `startCoach` subscription loop (line ~1979), replace the inline
await with a detached per-utterance task using `enqueue`, so a slow LLM can't make the
stream back up behind one utterance:

```swift
Task { [weak self] in
    do {
        if let result = try await orchestrator.enqueue(utterance: cu, windowText: windowText) {
            self?.applyCoachResult(result)
        }
        // nil = superseded under load — already surfaced via the cueSkipped health event.
    } catch {
        Loggers.bridges.debug("Coach ingest failed: \(error.localizedDescription, privacy: .public)")
    }
}
```

(Capture `let windowText = self.coachWindowText()` before spawning the task.) The
manual-trigger path (`runManualCoachTrigger`, line ~2566) can keep calling `ingest` or
switch to `enqueue` — identical behaviour for `userRequested`.

## 3. Dismiss vs minimise — re-point the global ⌥esc hotkey

The two header buttons are now honest and distinct:

- **Minimise** (`minus`, help “Minimise to pill”) → posts `.traceCoachOverlayHide` →
  collapses to the pill (unchanged behaviour).
- **Dismiss** (`xmark`, help “Dismiss for this meeting (⌥esc)”) → posts the **new**
  `.traceCoachOverlayDismiss` → genuinely hides the panel for the rest of the meeting.
  The pipeline keeps running (detections still land in the recent-cues log), but new
  cards no longer repopulate the hidden panel. The controller's local ⌥esc monitor now
  dismisses too.

New notification names (defined in `Sources/AppShell/CoachOverlay/CoachOverlayController.swift`):

```swift
Notification.Name.traceCoachOverlayDismiss   // "app.trace.coachOverlayDismiss"
Notification.Name.traceCoachOverlayReopen    // "app.trace.coachOverlayReopen"
```

New controller methods: `dismissForMeeting()`, `reopen()`.

**Wiring (one line)** — `registerGlobalControls()` (line ~272) currently registers the
global ⌥esc hotkey posting `.traceCoachOverlayHide`. Change it to post
`.traceCoachOverlayDismiss` so ⌥esc means the same thing whether Trace or the call app
is frontmost. (Until rewired, global ⌥esc minimises while local ⌥esc/the button
dismiss — inconsistent but harmless.)

**Reopen paths** (all already work, pick what to expose):
- a new meeting starting (`prepareForNewMeeting` / `present`) always clears dismissal;
- the manual trigger / Ask flow calls `present()`, which deliberately reopens — an
  explicit ask outranks a dismissal;
- a menu-bar “Show coach” item should post `.traceCoachOverlayReopen` (or call
  `coachOverlay?.reopen()`), shown only while a meeting is capturing.

## 4. Gating defaults — what actually turns the coach on (owner wants OFF by default)

Verified chain, by reading the code:

1. **Master switch** = `AppStateModel.coachEnabled`, persisted under
   `"app.trace.coach.enabled"`, **defaults TRUE** when unset
   (`AppStateModel.swift:981`: `… as? Bool ?? true`).
2. `CoachConfig.enabled` also defaults `true` (`CoachConfig.swift`), **but it is never
   the deciding bit**: `effectiveCoachConfig()` (coordinator :1863) and
   `effectiveCoachConfig(projectID:)` (:1873) force `cfg.enabled = state.coachEnabled`
   (AND the per-project flag). `startCoach` then guards on that forced value.
3. Onboarding’s `applyAIMode` (AppStateModel.swift:1061) sets `coachEnabled = false`
   for `.off` and **`true` for every AI mode** (cloud / Apple FM / Ollama).
4. **Loophole:** the triple-tap manual trigger monitor is gated only by
   `coachConfig.manualTrigger.enabled` (default true), not by `coachEnabled` — and
   `runManualCoachTrigger` (:2546) presents the overlay before any enabled check, so
   with the master switch OFF a triple-tap during a meeting still pops the pill (the
   pipeline then produces nothing because `config.enabled` is false). If the default
   flips to OFF this becomes the visible path; recommend guarding
   `runManualCoachTrigger` on `environment.state.coachEnabled`.

**To implement the owner's intent (beta features default OFF):** change
`AppStateModel.swift:981` to `?? false` (and the doc comment at :654 which says
“Default on”). Do NOT change `CoachConfig.enabled`’s default — it is dead weight in the
decision and changing it would also flip per-project configs decoded from partial JSON.
Decide separately whether `applyAIMode`’s blanket `coachEnabled = true` for AI modes
still matches the “parked feature” stance; suggest leaving it `false` there too and
letting the user opt in via Settings → the BETA toggle pattern.

## 5. Already handled at the data layer (no coordinator change needed)

- `applyCoachResult` builds `RecentTrigger(label: card.title, …)` from raw LLM titles.
  `RecentTrigger` moved to `Sources/CoachModule/RecentTrigger.swift` (same public
  initialiser — source-compatible) and its init now clamps empty/garbled/overlong
  titles to an honest per-mode fallback (“General cue”, “Synthesised cue”, …), so
  garbage can't render regardless of caller.
- Threshold constants consolidated in `Sources/CoachModule/CoachThresholds.swift` with
  their relationships documented and pinned by tests. **No behaviour change**: the
  orchestrator's no-regex gate (0.55) deliberately remains stricter than the router's
  synthesizable floor (0.50) — the gate is the “is this worth an LLM call” filter; the
  floor only matters once regex/manual already justified the call. The gate constant
  was renamed away from `topicShiftCosineThreshold` (it was comparing a RAG score
  against the topic-shift knob — same value, wrong name) to `ragAttentionMinCosine`.
- Overlay observation loop now arms on `present()`/`reopen()` and tears down on
  `hide()`/`dismissForMeeting()` instead of re-arming forever while hidden.
- Cue cards and the recent-cues log now show surfacing times.

## 6. Deferred / proposals (for Linear)

- Make the in-flight cap (currently a constant, 2) an Advanced-section setting if real
  meetings show it's mis-tuned.
- Menu-bar “Show coach” reopen item (section 3) needs a home in the menu-bar UI —
  outside coach territory.
- The `runManualCoachTrigger` master-switch guard (section 4, loophole).
