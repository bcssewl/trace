# Meetings subsystem — integration notes

Produced by the meetings agent. Everything below is either (a) coordinator
rewiring the meetings agent could not do itself (AppRuntimeCoordinator is owned
elsewhere) or (b) the agreed migration onto the audio agent's new
`MeetingStreamPipeline` API. All `MeetingRuntime` API changes are **additive**:
the existing `stop()`, `start()`, `saveNotes()` etc. keep their signatures and
semantics, so the coordinator compiles unchanged until the steps below are
applied.

## 1. Background finalise — switch the coordinator to detached stop

`MeetingRuntime` now exposes:

```swift
public func stop() async                          // unchanged: awaits the full tail
public func stop(detachedFinalize: Bool) async    // true → returns once capture is sealed
public var onFinalizeComplete: (@MainActor (String) async -> Void)?  // session id
public var isFinalizing: Bool                     // tail still running
```

`stop(detachedFinalize: true)` completes capture teardown + persistence
(pipeline drain, notes flush, `ended_at`) before returning; the heavy tail
(diarization refinement → title → summary merge → `summary.md`) continues as a
tracked task whose progress is shown via `MeetingLiveModel.summaryPhase`
(`preparing` / `generating` / `failed(message)` / `done`). `onFinalizeComplete`
fires on the main actor when the tail finishes — **in both stop forms, and also
when the summary failed** (the meeting is still finalised; the UI shows the
failure with a retry).

### Rewiring `runStopMeeting` (AppRuntimeCoordinator ~line 2384)

Current shape:

```swift
await runtime.stop()
self.stopCoach()
self.notchHUD?.hide()
await self.environment.state.meetingLibrary.refresh()
await self.runAutoCategorization()
await self.indexFinalizedMeeting()
await self.refreshRememberedSpeakerCount()
self.pruneAudioArchiveToBudget()
self.rearmMeetingAutoDetect()
```

Replace with:

```swift
await runtime.stop(detachedFinalize: true)
self.stopCoach()
self.notchHUD?.hide()
// List row should appear immediately (ended_at is already written):
await self.environment.state.meetingLibrary.refresh()
self.rearmMeetingAutoDetect()
```

and move the summary/transcript-dependent post-processing into the completion
hook, set once at runtime construction (in `ensureMeetingRuntime()`, next to
`notesSink`):

```swift
runtime.onFinalizeComplete = { [weak self] _ in
    guard let self else { return }
    await self.environment.state.meetingLibrary.refresh()   // generated title
    await self.runAutoCategorization()
    await self.indexFinalizedMeeting()
    await self.refreshRememberedSpeakerCount()
    self.pruneAudioArchiveToBudget()
}
```

Notes:
- `handleMeetingAutoStop` should route through the same path so auto-stopped
  meetings get identical treatment.
- `indexFinalizedMeeting` reads `environment.state.meetingLive.speakerNames`.
  That stays valid as long as no new meeting has begun; if one has, the live
  model belongs to the new meeting. Prefer reading the persisted
  `speakers.json` (`MeetingSpeakerNames`, written during the tail) keyed by the
  callback's session id instead of the live model.
- `invalidateMeetingRuntime()` may drop the runtime while a tail runs; that is
  safe — the tail holds the runtime alive until `summary.md` is persisted, and
  all of its UI writes are session-guarded.

## 2. Saved-meeting summary failure should use the failed phase

`regenerateSavedSummary(meta:model:steer:)` currently reports failure by
writing error text into the summary body (`model.setSummary("Couldn't build the
summary…", isFinal: true)`). `MeetingLiveModel` now has a first-class failure
state with a retry affordance in the view:

```swift
model.setSummaryFailed(
    "Couldn't build the summary. If you use Apple Intelligence, turn it on in System Settings → Apple Intelligence & Siri — or choose a different notes model in Settings → Meetings."
)
```

Use that in the `catch` of `regenerateSavedSummary` instead of `setSummary` so
saved meetings get the same "failed + Try again" UI as live ones. (Without this
change behaviour is unchanged — the old text-in-body style still renders.)

The "Summary missing — Generate now" affordance (meeting has a transcript but
no summary, e.g. crash-closed meetings reconciled at boot by the storage
agent's pass) needs **no coordinator change**: it keys off the hydration the
coordinator already does (`begin` + utterances + no `setSummary` call +
`regenerateSummary` wired).

## 3. MeetingStreamPipeline migration (audio agent's contract — NOT yet coded)

When the audio agent lands `finish(timeout:) async -> DrainResult` (drained vs
timedOut) and `onHealthEvent`, apply in `MeetingRuntime.teardownCapture()`:

```swift
// Replace:
await micPipeline?.finish()
await systemPipeline?.finish()

// With (timeout value: pick the agreed constant, e.g. 15s):
let micResult = await micPipeline?.finish(timeout: 15)
let sysResult = await systemPipeline?.finish(timeout: 15)
if micResult == .timedOut || sysResult == .timedOut {
    liveModel.raiseStorageNotice(
        "Some audio from the end of the meeting couldn't be transcribed in time — the transcript may stop early.")
    Loggers.meeting.error("Meeting pipeline drain timed out (mic=\(...), system=\(...))")
}
```

(Match the real enum case names when the API lands — do not guess.)

And in `start()`, when constructing each pipeline, wire the health callback to
the existing pill mechanism:

```swift
onHealthEvent: { [weak self] event in
    await MainActor.run {
        // dropped-segment / drain-timeout events:
        self?.liveModel.setCaptureNotice(<plain British-English text for the event>)
    }
}
```

Keep messages plain sentence case — `captureNotice` renders as a status pill
with the full text in `.help`. `raiseStorageNotice` (new) renders as a
dismissable warning banner; use it for events that mean data was lost, and
`setCaptureNotice` for ongoing-condition warnings.

## 4. LiveSummaryEngine

Now takes `(any ModelRoutingFacade)?` instead of `ModelRouter?` — the
coordinator's existing `LiveSummaryEngine(router: self.router, …)` call site
compiles unchanged (`ModelRouter` conforms). Additive knob:
`maxBufferChars: Int = 16_000` bounds the rolling transcript buffer for
multi-hour meetings (the last emitted summary is carried forward as condensed
context). No settings exposure needed; if ever surfaced, it belongs under
Advanced.

## 5. TraceError

No new cases needed; nothing requested.

## 6. Worktree baseline note

This worktree copied the current (uncommitted) main-checkout versions of
`MeetingRuntime.swift`, `MeetingLiveModel.swift`, `MeetingLiveView.swift` as
instructed, **plus** `Sources/SharedCore/Audio/SystemAudioCapture.swift`
*unmodified* — the main-checkout `MeetingRuntime` already depended on its new
`diagnostics().hasObservedNonZeroAudio` / `isDefaultOutputActive()` API and
would not compile against HEAD's copy. Merge coordinators: take the audio
agent's version of that file; this worktree made no changes to it.
