# Release Process

End-to-end checklist for cutting a Trace release. The build,
sign, notarize, package, and appcast steps are all scripted under
`scripts/`. Secrets live in the macOS Keychain, never on disk.

## 1. One-Time Setup

Each step is a one-time install per machine.

### 1.1 Xcode command-line tools

```bash
xcode-select --install
```

Verify that `codesign`, `xcrun notarytool`, `iconutil`, and `hdiutil`
are reachable on `$PATH`.

### 1.2 Developer ID identity

Install your "Developer ID Application" certificate via
Xcode > Settings > Accounts > Manage Certificates. The signing scripts
auto-detect the first available identity; pin a specific one by
exporting `DEVELOPER_ID_APPLICATION` before invoking
`scripts/build-app.sh`.

### 1.3 Notarization credentials

```bash
xcrun notarytool store-credentials "trace-notary" \
    --apple-id "<your-apple-id>" \
    --team-id  "<10-char-team-id>" \
    --password "<app-specific-password>"
```

The default profile name (`trace-notary`) is read by
`scripts/notarize-app.sh`; override with `NOTARYTOOL_PROFILE`.

### 1.4 Sparkle EdDSA key

```bash
./scripts/sparkle-sign.sh --generate-key
# Follow the printed instructions to add the PRIVATE key to your
# Keychain via `security add-generic-password`.
# The PUBLIC key goes into Resources/BootstrapConfig.json (sparkle.publicEDKey)
# and into Resources/Info.plist.in (SUPublicEDKey).
```

The release pipeline reads the private key with
`security find-generic-password -s app.trace -a sparkle.ed25519 -w`.

### 1.5 Sparkle framework

The bundling script copies `Sparkle.framework` from one of:

1. The path in `SPARKLE_FRAMEWORK_PATH`.
2. `Frameworks/Sparkle.framework` in the repo (not checked in).
3. `/Library/Frameworks/Sparkle.framework` on the host.

Download Sparkle 2.7+ from the official release page and drop the
framework into `Frameworks/`. The script signs and embeds it during
`bundle-app.sh`.

## 2. Cut a Release

```bash
git checkout main
git pull --ff-only
git tag v0.1.0
git push --tags

# Full pipeline. Defaults: version from git describe, build number from
# the commit count. All secrets read from Keychain.
./scripts/build-app.sh
```

The pipeline prints each stage. Output lands in `dist/`:

```
dist/
  Trace.app              # signed + notarized + stapled
  Trace-0.1.0.dmg        # signed
  appcast.xml                    # EdDSA-signed Sparkle feed
```

### 2.1 Partial runs

| Flag | Stops after |
|------|-------------|
| `--skip-sign` | bundle |
| `--skip-notarize` | signing |
| `--skip-dmg` | notarization |
| `--skip-sparkle` | DMG creation |

Useful for local iteration without burning notarization quota.

## 3. Distribute

1. Upload `dist/Trace-<version>.dmg` to the GitHub release.
2. Commit `dist/appcast.xml` to the publishing branch (default:
   `gh-pages`) so Sparkle clients see the new version.
3. Update the `SUFeedURL` in `Resources/BootstrapConfig.json` if the
   feed location changes (one-time; defaults to the project's GitHub
   Pages URL).

## 4. Verification After Release

```bash
# Confirm the bundle is hardened, notarized, and stapled.
spctl --assess --type execute --verbose=4 dist/Trace.app

# Inspect the appcast.
xmllint --noout dist/appcast.xml
```

## 5. Troubleshooting

| Failure | Fix |
|---------|-----|
| `notarytool` rejects with `Invalid` | run `xcrun notarytool log <id> --keychain-profile trace-notary` and address the listed signing or entitlements gap |
| `codesign` cannot find identity | run `security find-identity -v -p codesigning` and pin via `DEVELOPER_ID_APPLICATION` |
| Sparkle clients ignore an update | inspect `appcast.xml` for missing `sparkle:edSignature` or mismatched `length`; re-run `scripts/generate-appcast.sh` |
| `sign_update` not found | install Sparkle 2.7+ release archive; export `SIGN_UPDATE=/path/to/sign_update` |

## 6. Tool-Gap Notes

These tools are required and not auto-installed. The scripts fail loud
with an install hint if any are missing:

- `iconutil` (Xcode CLT)
- `hdiutil` (system)
- `codesign` (Xcode CLT)
- `xcrun notarytool` (Xcode 13+)
- `xcrun stapler` (Xcode CLT)
- `sign_update` (Sparkle release archive)
