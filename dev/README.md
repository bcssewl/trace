# Trace Dev Target

This is the everyday development entry point for Trace. It produces a
real macOS `.app` bundle with a stable bundle identifier
(`app.trace.dev`), the same `Info.plist` privacy keys + entitlements
as the release bundle, and runs the exact same `AppShell` + `SharedCore`
source as the SwiftPM executable — but launches under Xcode's debugger so you
get incremental builds, breakpoints, and live console output.

The dev bundle ID is intentionally distinct from the release bundle ID so
macOS TCC keeps the two app identities' permissions separate.

## Daily workflow

```bash
./scripts/dev-xcode.sh
```

That regenerates `dev/TraceDev.xcodeproj` from `dev/project.yml` (so
any new `Sources/` are picked up) and opens it in Xcode. Then:

1. Pick the `TraceDev` scheme (it's the only one).
2. Press ⌘R.
3. The app launches as a real `.app` bundle. TCC prompts behave the same way
   they would in the release build.

Edit code in `Sources/...` as normal — Xcode rebuilds incrementally on ⌘R.
The Xcode project tree only carries the dev entry point + Info.plist +
entitlements + AppIcon assets; all real code lives under `Sources/` and is
pulled in as the local `Trace` SwiftPM package.

## Resetting dev TCC permissions

```bash
tccutil reset Microphone app.trace.dev
tccutil reset Accessibility app.trace.dev
tccutil reset Calendar app.trace.dev
```

(System Audio Recording can't be reset via `tccutil`; go to
System Settings → Privacy & Security → Screen Recording and remove the entry.)

## Testing the release `.app`

```bash
./scripts/build-app.sh --skip-sign --skip-notarize --skip-dmg --version 1.0.0 \
  && codesign --force --deep --sign - \
       --entitlements dist/Trace.app/Contents/Trace.entitlements \
       dist/Trace.app \
  && open dist/Trace.app
```

That's the only flow that exercises the production bundle identifier
(`app.trace`). Use it when you specifically want to test the release
bundle, the full sign + notarize path, or the Sparkle update wiring. Don't
use it as the daily edit loop.

## Building release artifacts

```bash
./scripts/build-app.sh --version 1.0.0
```

Drops a `.app`, a notarized + stapled bundle, and a DMG into `dist/` when run
with full credentials (Developer ID identity + notarization profile). See
`scripts/build-app.sh --help` for the credential flags.

## Why XcodeGen?

The Xcode project is generated from `dev/project.yml` so the source of truth
for build settings + scheme stays in plain YAML and adding a new SwiftPM
target doesn't require manually editing `project.pbxproj`. The generated
`.xcodeproj` is gitignored; everyone regenerates locally.

Install XcodeGen once: `brew install xcodegen`.
