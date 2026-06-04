# Trace

Trace is a native macOS app that keeps dictation, meeting notes, voice memos, file
transcription, and an in-meeting coach in one place. No pile of subscriptions, no
cloud bot sitting in on your calls. It is local-first by design: everything runs on
your Mac unless you explicitly opt in to a cloud model.

On-device by default. Apple's speech and Foundation Models, on-device transcription
(Parakeet, [WhisperKit](https://github.com/argmaxinc/WhisperKit), Qwen3),
[FluidAudio](https://github.com/FluidInference/FluidAudio) for speaker labelling, and
a local [Ollama](https://ollama.com) endpoint for language tasks. Cloud models
(OpenRouter, hosted transcription) are strictly opt-in: you bring your own key, and
nothing leaves the machine unless you ask it to.

https://github.com/user-attachments/assets/dc1ba630-79aa-4943-8dd3-d19e6ffc3f08


## What it does

- **Dictation.** Global push-to-talk that drops cleaned-up text at the cursor in any
  app. Per-app modes, a personal dictionary, and optional AI clean-up. On-device
  speech by default, with multilingual transcription that handles code-switching
  (for example English mixed with Arabic or Chinese). Cloud transcription if you want
  it.
- **Meetings.** Captures your microphone and the system audio locally through
  CoreAudio process taps, so there is no meeting bot and no uploaded recording.
  On-device speaker labelling, and AI summaries that merge your own notes with the
  transcript.
- **Voice memos and file transcription.** Quick hands-free capture, drag-and-drop
  audio or video, and watched folders that transcribe new files on their own.
- **Coach.** An optional, screen-share-invisible overlay that surfaces cue cards
  during a meeting, grounded in your own playbook documents and scoped to the current
  project so it never pulls in unrelated material. It only speaks when you ask it to,
  via a manual trigger.
- **Library.** Local full-text and semantic search across every meeting and
  dictation, plus cited cross-meeting Q&A.

## Privacy

Your data lives in a local SQLite database and plain Markdown files under
`~/Documents/Trace` and `~/Library/Application Support/Trace`. Nothing is hidden in a
proprietary store: you can read it, back it up, or delete it yourself. API keys are
kept in the macOS Keychain. Cloud calls only happen for stages you have explicitly
pointed at a cloud model, and Trace tells you which stage uses which model.

## Download

Grab the latest `Trace-<version>.dmg` from the
[**Releases**](https://github.com/bcssewl/trace/releases) page, open it, and drag
Trace into Applications.

The build is **not notarised by Apple** (it's a free, self-published release), so
macOS Gatekeeper stops it the first time:

> "Trace" cannot be opened because the developer cannot be verified.

This is expected. To run it the first time (macOS 15 Sequoia and later — including
macOS 26 — removed the old right-click → Open shortcut, so this is the current
path):

1. Double-click Trace once; macOS refuses to open it.
2. Open **System Settings → Privacy & Security**, scroll to the **Security**
   section near the bottom. You'll see *"Trace was blocked to protect your Mac"*
   with an **Open Anyway** button — click it, then confirm and authenticate with
   your password. macOS remembers the choice, so you only do this once.
3. If macOS instead says the app is *"damaged and can't be opened"*, that's the
   download-quarantine flag. Clear it with:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Trace.app
   ```

Prefer to build it yourself instead? See [Build & run](#build--run) below.

## Requirements

- macOS 26+ on Apple Silicon
- Swift 6.2 / Xcode 26 command-line tools
- Optional: [Ollama](https://ollama.com) for local language stages, and an OpenRouter
  or hosted-transcription API key for cloud stages (configured in-app, stored in the
  Keychain)

## Build & run

```bash
# Build the SwiftPM binary
swift build -c release

# Bundle into a runnable .app (unsigned, the fastest local path)
./scripts/build-app.sh --skip-sign --skip-notarize --skip-dmg

# Launch it
open dist/Trace.app
```

To produce a shareable **unsigned `.dmg`** locally (ad-hoc signed so it launches,
no Apple account needed — the same artifact CI publishes to Releases):

```bash
./scripts/build-app.sh --adhoc --version 0.1.0
# → dist/Trace-0.1.0.dmg
```

**Running it yourself, day to day?** Use the local stable-signing path instead.
A one-time setup mints a stable self-signed certificate; every build then carries
the *same* signature, so macOS keeps the app's Microphone / Accessibility / etc.
permissions across rebuilds instead of re-prompting each time (ad-hoc builds get a
fresh signature every time, which wipes permissions):

```bash
./scripts/setup-local-signing.sh        # once
./scripts/build-local.sh --install      # build, sign stably, install to /Applications
```

This is local-only — the self-signed cert isn't trusted on other Macs, so it's not
for distribution. For a Gatekeeper-clean, notarised release you need a paid Apple
Developer account; that pipeline lives in [`docs/RELEASE.md`](docs/RELEASE.md) and
the `release.yml` workflow.

For day-to-day development under Xcode's debugger, see
[`dev/README.md`](dev/README.md) (`./scripts/dev-xcode.sh`).

## Test

```bash
swift test
```

A pre-commit hook lints with `swift format` and runs the suite on every commit; run
it by hand with `./scripts/pre-commit`.

## Release

The signing, notarisation, DMG, and Sparkle-appcast pipeline is scripted and
documented in [`docs/RELEASE.md`](docs/RELEASE.md):

```bash
./scripts/build-app.sh --version "$(git describe --tags | sed 's/^v//')"
```

## Project layout

```
Package.swift            SwiftPM manifest (Swift 6.2, macOS 26)
Sources/
  SharedCore/            Core engine: audio, speech, model routing, storage, bridges
  AppShell/              SwiftUI surfaces + the runtime coordinator
  DictationModule/       Thin feature seams over SharedCore
  MeetingModule/
  FileBatchModule/
  CoachModule/
  Trace/                 Executable entry point (@main)
Resources/               Info.plist template, entitlements, app icon
Tests/                   XCTest targets mirroring Sources/
scripts/                 Build, sign, notarize, DMG, and Sparkle helpers
docs/                    Release documentation
```

The bulk of the logic lives in `SharedCore`. The per-feature modules are deliberately
thin boundaries that compose it, and `AppShell` wires everything into the UI. Model
choices are routed per task (dictation clean-up, meeting notes, the coach, library
Q&A), so each can run on-device or in the cloud independently.

## On the build

I designed and built Trace end to end: the product, the architecture, the local-first
principles, and the implementation. I built it pair-programming with Claude
(Anthropic's coding agent) as a force multiplier, directing the design and the
engineering decisions throughout, from the per-task model routing down to the
CoreAudio process taps and the Swift 6 concurrency. The product thinking and the
system are mine; the AI let me build it faster.

## License

[MIT](LICENSE). Third-party dependencies and their licences are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Provider names and logos shown in the app (OpenAI, Anthropic, Google, Apple, and
others) are trademarks of their respective owners, used only to identify those
services. They are not covered by the MIT licence and imply no affiliation or
endorsement.
