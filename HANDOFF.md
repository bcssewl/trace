# Trace — session handoff

_Last updated end of the 2026-06-11→15 real-life-testing + hardening sessions._

## Current state
- Latest release: **v0.6.0** (build ~15). `main` HEAD = the v0.6.0 commit.
  Shipped via `./scripts/ship.sh vX.Y.Z` (pushes main, tags, CI builds + publishes
  the DMG + Sparkle appcast). Only tags trigger a build.
- Installed app lives at `/Applications/Trace.app` (one canonical copy — see below).
  Dev build is `Trace Dev.app` in Xcode DerivedData (bundle id `app.trace.dev`).

## What shipped this session (v0.4.0 → v0.6.0)
- **v0.4.0** — meeting hardening: loud/fast "only recording you" deaf-tap warning
  (15s, also fires on zero frames, full banner); faster meeting detection (1s poll,
  immediate first tick, 2s gate, audio-only fallback for unrecognised apps via a
  new Settings toggle); title-aware project auto-filing (classifier gets the meeting
  title + per-project example titles + whole-meeting transcript samples) + an
  "All projects…" picker on the banner; reopenable coach cues + honest idle text.
- **v0.5.0** — permissions rework: `PermissionRequester.systemAudioLiveStatus()`
  probes the real CoreAudio tap grant instead of trusting a stale UserDefaults
  cache; meeting-start **pre-flight** (request mic, probe system audio BEFORE
  recording — no 15s surprise); `verifyLaunchPermissions()` on boot; new
  **Settings → Permissions** panel + shared `PermissionCatalog`; onboarding
  "Enable all" button.
- **v0.6.0** — dictation cancel now needs **Esc pressed twice** (first press shows
  "Press Esc again to cancel" in the notch, 2s window; one stray Esc no longer wipes
  a long recording). `EnterKeyInterceptor` gained a continuous (non-one-shot) mode +
  key-repeat filtering; new `NotchKind.confirmCancel`.

## Key root cause (THE lesson)
The user's "only records me, not the other person" + "every relaunch I re-grant
permissions" was **not a code bug**. macOS binds TCC grants to the binary's code
identity; the self-signed app had TWO copies (`/Applications` 0.3.0 and a `dist/`
0.4.0 build) with the same bundle id — the grant attached to one while he ran the
other, so the system-audio tap created fine but yielded silence. Fixed by
consolidating to one /Applications copy, `tccutil reset ScreenCapture/Microphone
app.trace`, and re-granting. Full write-up: `docs/macos-lessons.md`.

## Decisions / why
- No Apple Developer Program ($99/yr) → self-signed, not notarised; stable cert
  across releases so users keep grants. System-audio tap forces the app unsandboxed.
- System-audio permission has **no read-only API** → must probe live; never trust a
  cached "granted".
- Permissions: ask up front (onboarding) + verify on launch + pre-flight critical
  ops + fail loud. Never silent fallback.

## Dead ends ruled out
- Not app translocation/quarantine (running from /Applications, no quarantine xattr).
- Not a code/version skew between main & dev apps (were byte-identical at one point).
- The deaf tap is mode-2 (creates OK, yields silence) for wrong-binary — NOT a
  creation error — so a probe-creation check alone can't catch it; the in-meeting
  audio-level watchdog stays as the backstop.

## Cross-project artifact
- `docs/macos-lessons.md` — canonical hard-won macOS-app lessons (signing/TCC,
  permissions, distribution, Sparkle, packaging). Copied to `/Users/bassel/CONSO/
  docs/macos-lessons.md` for the user's new app (CONSO). Keep this Trace copy as the
  maintained source.

## Open threads / next steps
- **BAS-94** settings parity between Trace & Trace Dev (per-bundle UserDefaults/
  Keychain divergence).
- **BAS-95** live verification of the System Audio Recording grant (a real
  launch/Settings probe + re-grant flow; the doc + 15s warning are interim).
- **BAS-96** event-driven meeting detection (CoreAudio listeners instead of polling).
- User still needs to: install v0.6.0 once CI publishes; re-grant Screen & System
  Audio Recording + Microphone for `/Applications/Trace.app` (reset earlier); align
  the main app's Meetings ASR engine + Coach OpenRouter key with the dev app
  (per-bundle, don't carry over).

## Key paths
- Permissions: `Sources/SharedCore/Bridges/Permissions/{PermissionRequester,PermissionGate}.swift`,
  `Sources/AppShell/Settings/PermissionsCenterView.swift` (catalog + panel),
  `Sources/AppShell/App/AppRuntimeCoordinator.swift` (`verifyLaunchPermissions`,
  meeting pre-flight in `runStartMeeting`).
- Dictation Esc cancel: `Sources/SharedCore/Bridges/Accessibility/EnterKeyInterceptor.swift`,
  `AppRuntimeCoordinator.handleEscapeWhileDictating`, `NotchHUDController` (`.confirmCancel`).
- Meeting detection: `Sources/SharedCore/Bridges/Workspace/{AppActivityMonitor,MeetingSignalSources}.swift`.
- Auto-categorization: `Sources/MeetingModule/AutoCategorization/*`.
- Release: `scripts/ship.sh`, `.github/workflows/release-unsigned.yml`.
