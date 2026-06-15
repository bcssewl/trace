# Building macOS apps — hard-won lessons

Read this before doing any code-signing, permissions, packaging, or release work
on a macOS app. These are the traps that cost real time on Trace — not generic
Swift advice, but the non-obvious things that only bite once you ship and run a
real signed app. Distilled from the full build history, not just the last fix.

**TL;DR:** A macOS permission is bound to the app's *code signature*, not its
name — so a self-signed app silently loses every grant whenever its binary
changes or a second copy exists, while System Settings still shows it "on." Never
trust a cached "granted"; verify live. Ask for all permissions up front, verify on
launch, and pre-flight before any capture — never discover a missing grant
mid-operation. Use ONE stable self-signed cert for every build, install to
/Applications and run only from there, and bump the build number every release or
the updater silently refuses to update.

---

## 1. Code signing & TCC permissions — the #1 time sink

- **TCC binds a permission to the binary's code identity, not the bundle name.**
  Developer-ID app → bound to the cert. Self-signed/ad-hoc app → effectively bound
  to the exact binary (its CDHash). Change the binary and the grant is silently
  voided.
- **"On" in System Settings ≠ the running binary has it.** The toggle can point at
  an old or duplicate signature. The app's own cached "granted" belief lies too.
  The only truth is asking the OS live.
- **Never keep two copies of the app with the same bundle id.** The grant attaches
  to whichever copy prompted; launch the *other* (e.g. a `dist/` build vs the
  /Applications install) and it's silently broken — records nothing, or one-sided,
  with no error. Install to /Applications and run ONLY from there.
- **Every rebuild into a build folder is a new identity → permissions reset.**
  This is the "every time I relaunch I have to re-grant" symptom — it's not random.
- **For dev builds, use a STABLE self-signed certificate, never ad-hoc.** Ad-hoc
  mints a fresh identity per build and wipes TCC grants every rebuild. A named
  self-signed cert (the same one each build) keeps grants across rebuilds. Bake it
  into the project config so you never re-sign by hand.
- **To fix a tangled grant:** `tccutil reset ScreenCapture <bundleid>` (also
  `Microphone`, `Accessibility`, …), then relaunch and re-grant. Toggling the
  Settings switch is not enough once a grant is bound to a dead identity.
- **App translocation / quarantine:** a downloaded, quarantined app run from
  Downloads or straight off a DMG executes from a randomized read-only path, so
  granted permissions don't stick. Moving it to /Applications via Finder clears the
  quarantine flag. Confirm the *running* path with `ps` (not an `AppTranslocation`
  path) and check `xattr -l` for `com.apple.quarantine`.

## 2. Entitlements, sandbox & usage strings

- **System-audio capture forces you OUT of the App Sandbox.** The CoreAudio
  process-tap can't run sandboxed, so an app that records other call participants
  must ship unsandboxed — which also means **no Mac App Store**. Decide this early;
  it shapes distribution.
- **Each TCC permission needs its `…UsageDescription` string in Info.plist, or the
  app SIGABRTs the instant it requests that permission.** Mic →
  `NSMicrophoneUsageDescription`, system audio → `NSAudioCaptureUsageDescription`,
  calendar → `NSCalendarsFullAccessUsageDescription`, Apple-Events/automation →
  `NSAppleEventsUsageDescription`, speech → `NSSpeechRecognitionUsageDescription`,
  notifications → `NSUserNotificationsUsageDescription`.
- **Hardened runtime needs the matching entitlements:**
  `com.apple.security.device.audio-input` (mic),
  `com.apple.security.automation.apple-events` (scripting other apps), and
  `com.apple.security.cs.disable-library-validation` if you load third-party
  frameworks/dylibs (e.g. an ML runtime). Missing one → silent denial or crash.

## 3. Permissions UX — build it this way from the start

- **Some permissions have NO read-only status API** (Screen & System Audio
  Recording is the big one). You can only learn the status by *attempting the
  operation*. So probe live, and never persist a "granted" result as truth — it
  goes stale the instant the OS revokes it.
- **Tap-creation success is NOT proof of working capture.** The system-audio tap
  (`AudioHardwareCreateProcessTap` / `CATapDescription`, macOS 14.4+; use a *global*
  tap to register under "Screen & System Audio Recording") can create successfully
  yet deliver only digital silence when the grant isn't effective. Confirm by
  observing real (non-zero) audio.
- **Ask for everything up front** in onboarding (offer an "Enable all"), not the
  first time each feature is used. Lazy per-feature prompts hide missing grants
  until mid-task.
- **Verify on launch.** The app should know on open whether it has what it needs,
  and surface anything missing with a button to the exact fix.
- **Pre-flight before any capture.** Check (live) before you start recording — not
  by discovering silence N seconds in.
- **Fail loud; never silently degrade.** A capture that records one-sided, or falls
  back to a worse path, without telling the user is the worst bug class. Detect it
  fast and point to the exact Settings pane.

## 4. Distribution without a paid Apple Developer account ($99/yr)

- No account → no Developer ID, no notarization. Self-signed/local-signed is the
  ceiling; treat builds as personal, not freely public-distributable. (A full
  notarize pipeline is wasted effort until you have the account.)
- First launch needs the Gatekeeper override, and **macOS 15+ removed the
  right-click → Open shortcut** — the path is now System Settings → Privacy &
  Security → "Open Anyway." Document this for any user.
- **Sign every release with ONE stable cert.** A shared signature across releases
  is what lets users keep their granted permissions and Gatekeeper approval across
  updates, instead of re-granting every time.

## 5. Auto-update (Sparkle)

- **Sparkle compares the build number (`CFBundleVersion`), not the marketing
  version.** If a new release's build number isn't strictly greater, the updater
  says "you're up to date" forever — even when the version *name* changed. Bump the
  build number every single release, monotonically.

## 6. Dev vs release builds drift silently

- **UserDefaults (`.standard`), Keychain, and TCC are all per-bundle-id.** A dev
  build and a release build (different bundle ids) diverge even on byte-identical
  code — different settings, different API keys, different permission grants. The
  data folder / DB is often *shared*, which makes it look like a code bug.
- When two builds "behave differently," check per-bundle **state** first
  (`defaults read <bundleid>`, `codesign -dvv`, *which* binary is actually running)
  before suspecting code or version skew.
- **Keychain items are freely readable only by the app that created them.** A
  re-signed or sibling copy gets an auth prompt or access-denied — a key saved by
  the release app won't silently work in the dev app.

## 7. Packaging & runtime sharp edges

- **Put SwiftPM resource bundles at the `.app` root** so `Bundle.module` resolves.
  Otherwise it works on the build host and crashes on launch for everyone else — a
  brutal "works on my machine" failure.
- **Launch a dev build via `open`, never by exec'ing the inner binary directly.**
  Direct exec breaks TCC's usage-string attribution → SIGABRT the moment it
  requests mic/speech access.
- **`@main` entry must be a *synchronous* `main()`.** An `async main()` double-pumps
  the run loop and silently breaks main-thread work; bridge async startup with a
  semaphore instead.
- **Loopback OAuth must bind IPv6** — `localhost` resolves to `::1`, so an
  IPv4-only listener refuses the callback ("connection refused" with no obvious
  cause).
