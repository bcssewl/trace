# Audio capture + speech pipeline — integration notes

Scope of the audio-subsystem branch. Everything here is **additive / source-compatible**:
no existing call site needs changes to compile. The "Call-site migrations" section lists
what the runtime owners (MeetingRuntime / coordinator) should adopt to get the full benefit.

## What changed

### `SharedCore/Audio/SerialRebuildCoordinator.swift` (new)
- `SerialRebuildCoordinator` — one serial dispatch queue per capture through which **every**
  pipeline mutation (start/stop/teardown/rebuild) runs. `requestRebuild` coalesces: requests
  arriving while a rebuild is queued are dropped; requests arriving while one is *executing*
  schedule exactly one trailing pass. `isRebuildPendingOrActive` lets the watchdog stand down
  mid-rebuild.
- `CaptureHealthEvent` (public enum) — shared by both captures:
  `watchdogTriggeredRebuild(silentSeconds:)`, `deviceChangeTriggeredRebuild`,
  `driftTriggeredRebuild(declaredHz:measuredHz:)`, `configurationChangeTriggeredRebuild`,
  `rebuildSucceeded`, `rebuildFailed(reason:)`.

### `SharedCore/Audio/SystemAudioCapture.swift`
- **Rebuild race fixed**: watchdog ticks and device-change events no longer call `rebuild()`
  directly from their own threads. Both go through the coordinator; start/stop run exclusively
  on the same queue, so the HAL never sees overlapping tearDown/buildPipeline passes.
  `watchdogTimer` / `deviceWatcher` / `deviceWatcherTask` are now mutated only on that queue.
- Watchdog ticks are ignored while a rebuild is pending or in flight.
- **IO-proc buffer pool**: `handleIOProc` takes buffers from an `AudioBufferPool`
  (pre-allocated on every pipeline build, rebuilt on format change) and falls back to fresh
  allocation when the pool is empty — so an uncooperative consumer gets exactly the old
  behaviour, never corruption. New API: `recycle(_ buffer:)` (see migrations) and
  `bufferPoolStats`.
- New: `setOnHealthEvent(_:)`. Watchdog/device-change rebuilds and their outcomes are emitted;
  `rebuildFailed` means capture has STOPPED (stream finished) and must be surfaced loudly.
- **Behaviour change**: `stop()` now finishes the `buffers` stream (it previously stayed open
  forever). This makes the documented contract in MeetingRuntime ("stop captures first so each
  stream finishes") actually true, which is what lets the pipeline drain cleanly. The instance
  is therefore **single-use**: `start()` after `stop()` throws
  `TraceError.audioCaptureFailed` instead of silently capturing into a dead stream.
  (Both production call sites — MeetingRuntime and AudioPipeline — already create a fresh
  instance per session.)
- Device-change log now includes the new output device's name.

### `SharedCore/Audio/AudioBufferPool.swift` (new)
- Lock-protected LIFO pool with identity-checked recycling (double-recycle ignored), format
  and capacity validation, cap (16), pre-allocation (8 × 4096 frames), and hit/miss stats.

### `SharedCore/Audio/MicCapture.swift`
- **Drift-rebuild race fixed**: the drift path (fired from the Core Audio tap) and the
  configuration-change observer now request a coalesced rebuild on the same serial queue that
  start/stop/teardown use. `engine` / `configChangeObserver` / `rateTracker` are queue-protected.
- New: `setOnHealthEvent(_:)` (same `CaptureHealthEvent` enum). Drift and config-change
  rebuilds emit trigger + outcome; `rebuildFailed` means the mic is dead.
- No change to the warm-engine lifecycle, `subscribe()` semantics, or the
  `MicrophoneBufferProducing` conformance.

### `AppShell/Runtime/MeetingStreamPipeline.swift`
- New public `PipelineHealthEvent`: `asrSegmentDropped(stream:reason:seconds:)`,
  `audioConversionFailed(stream:reason:)` (once per failure streak), `drainTimedOut(stream:)`.
  Wire via the new defaulted init parameter `onHealthEvent:` or `setOnHealthEvent(_:)`.
- New `finish(timeout: Duration) async -> PipelineDrainResult` with
  `PipelineDrainResult = .drained | .drainedIdle | .timedOut`:
  - `.drained` — source finished its stream; every buffered sample reached transcript/archive.
  - `.drainedIdle` — stream still open, but the producer was idle and the backlog empty
    (the warm mic never closes its subscriber streams by design); nothing lost.
  - `.timedOut` — deadline expired with audio still unprocessed; the in-flight segment is
    flushed, the rest dropped, and a `.drainTimedOut` health event fires.
  Idle detection (300 ms of no consumed-sample progress with no ASR inference in flight)
  means an open-but-quiet stream returns in ~350 ms instead of burning the whole timeout.
  `timeout <= .zero` = legacy immediate-cancel.
- Legacy `finish()` now delegates to `finish(timeout: .milliseconds(500))` — bounded, drains
  the backlog in the common case, never hangs meeting stop.
- **Timestamps**: stream-relative time is now derived from the exact integer count of consumed
  16 kHz samples (`samplesConsumed / 16000`) instead of accumulating per-buffer float durations
  — sample-accurate across hours and across slow ASR stalls.
- Converter churn is logged (`building audio converter: … (input format changed from …)`).
- New defaulted init parameter `recycler:` — called once per source buffer after the pipeline
  has copied everything out of it (feeds the capture's buffer pool).

### `SharedCore/Speech/Backends/AppleSpeech/AppleSpeechBackend.swift`
- `AppleSpeechRetryPolicy` (public, testable): max attempts (3), exponential backoff
  (0.5 s × 2, cap 8 s), minimum request gap (0.25 s), and rate-limit classification
  (kAFAssistantErrorDomain code 203 "Retry" + conservative wording heuristics — Apple has no
  documented throttle contract).
- `AppleSpeechRequestGate` (public): **process-wide** FIFO serialisation + pacing. The meeting
  runtime resolves a separate backend instance per stream, but Apple's throttle is system-wide,
  so the gate is shared (`AppleSpeechRequestGate.shared`; injectable for tests).
- Rate-limited segments are retried with backoff; when finally dropped the backend **throws**
  `TraceError.asrInferenceFailed(engine: "apple-speech", reason: "rate-limited — segment
  dropped after N attempts: …")` — never a silent drop. The pipeline converts that into an
  `asrSegmentDropped` health event.
- `AppleSpeechBackend()` still compiles everywhere (new init parameters are defaulted).

## Call-site migrations (for the MeetingRuntime / coordinator owners)

1. **Drain with an explicit deadline** (replaces the two `await …finish()` calls in
   `MeetingRuntime.stop()`):
   ```swift
   mic?.stop()
   system?.stop()                                   // now finishes the system stream
   let micResult = await micPipeline?.finish(timeout: .seconds(15))
   let sysResult = await systemPipeline?.finish(timeout: .seconds(15))
   ```
   Expected: system → `.drained` (full archive for offline diarization); mic → `.drainedIdle`
   (its subscriber stream stays open by design). `.timedOut` on either is genuine tail loss —
   surface it (see strings below).

2. **Wire pipeline health events** (init param `onHealthEvent:` or `setOnHealthEvent`).
   Suggested handling: count `asrSegmentDropped` per meeting and show one aggregated, loud
   notice (British English):
   > "3 segments couldn't be transcribed — consider choosing a different transcription engine
   > in Settings → Meetings."
   `drainTimedOut` → "Some audio at the end of the meeting wasn't processed."
   `audioConversionFailed` → treat like a capture fault (audio is being dropped).

3. **Wire capture health events** (`mic.setOnHealthEvent` / `system.setOnHealthEvent`):
   - trigger events (`watchdogTriggeredRebuild`, `deviceChangeTriggeredRebuild`, drift/config) →
     transient info notice, e.g. "Audio capture recovering…", cleared on `rebuildSucceeded`
     ("Audio capture recovered").
   - `rebuildFailed` → capture is DEAD and its stream finished; show an error notice
     ("System audio capture stopped — restart the meeting to resume recording.") instead of
     silently producing a one-sided recording. This replaces today's behaviour where a failed
     rebuild only wrote a log line.

4. **Enable the IO buffer pool** for the system stream by passing the recycler when building
   the system pipeline:
   ```swift
   let systemPipeline = MeetingStreamPipeline(
       …,
       recycler: { [weak system] buffer in system?.recycle(buffer) },
       …)
   ```
   Do NOT wire `system.recycle` to the mic pipeline (mic buffers come from `AVAudioEngine`'s
   tap, not the pool; they'd simply be rejected, but it's pointless work). Without this wiring
   the pool idles and the IO proc allocates per callback exactly as before.

5. **Single-use captures**: keep creating fresh `MicCapture` / `SystemAudioCapture` instances
   per meeting (already the case). A `SystemAudioCapture` restart after `stop()` now throws.

## TraceError

No new cases required — existing `asrInferenceFailed` / `audioCaptureFailed` /
`permissionDenied(.systemAudio)` fit everything above. **Optional request**: a dedicated
`asrRateLimited(engine: String)` case (recovery action `.retryWithBackoff`) would let the UI
distinguish "engine is throttled, try later or switch" from a hard inference failure; today
that distinction rides in the reason string ("rate-limited — segment dropped after N attempts").

## Known gaps (candidates for Linear)

- **VAD leading truncation** (pre-existing): `speechStart` seeds the segment with only the
  triggering buffer, so the first `minimumSpeechFrames − 1` buffers (~0.25 s) of each utterance
  never reach the ASR. Fix would be a small pre-roll ring of recent buffers.
- **Mic drain can't observe end-of-stream**: `MicCapture` deliberately keeps subscriber streams
  open across cycles (warm reuse), so the mic pipeline reports `.drainedIdle`, not `.drained`.
  If a true `.drained` is ever wanted, add e.g. `subscribe(finishOnStop: true)`.
- **`AudioPipeline` restart**: pumping the single-shot `buffers` stream means a second
  `startSystem()` after `stopSystem()` was already a dead stream before this branch; with the
  single-use guard it now fails loudly instead.

## Tests added

- `Tests/SharedCoreTests/Audio/SerialRebuildCoordinatorTests.swift` — coalescing (16 overlapping
  requests → exactly one trailing pass), strict serialisation under concurrent hammering,
  busy-flag lifecycle, rethrow.
- `Tests/SharedCoreTests/Audio/AudioBufferPoolTests.swift` — reuse identity, miss conditions,
  recycle rejection (format/size/cap/double-recycle), format-change rebuild, steady-state
  zero-miss loop.
- `Tests/SharedCoreTests/Audio/SystemAudioCaptureTests.swift` (extended) — watchdog rebuild +
  health events in test-hooks mode, concurrent rebuild coalescing with a held rebuild
  (no overlap, exactly 2 passes), stop-finishes-stream + restart-throws, pool recycle safety.
- `Tests/SharedCoreTests/AppleSpeechRetryPolicyTests.swift` — backoff progression/cap,
  rate-limit classification, gate FIFO + non-overlap, failure releases gate, pacing gap.
- `Tests/AppShellTests/MeetingStreamPipelineDrainTests.swift` — idle never-finishing stream
  (early return + flush), actively-producing stream (returns at deadline, `.timedOut`,
  `drainTimedOut` event, flush), clean drain, sample-accurate timestamps across a 400 ms ASR
  stall, `asrSegmentDropped` on ASR failure, recycler called once per buffer.
