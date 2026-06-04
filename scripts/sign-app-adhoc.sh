#!/usr/bin/env bash
# scripts/sign-app-adhoc.sh
#
# Ad-hoc codesigns the bundled Trace.app — no Developer ID, no hardened
# runtime, no notarization. This is the minimum required for an Apple Silicon
# app to LAUNCH at all (a fully unsigned arm64 binary is killed on exec); it is
# NOT a substitute for Developer ID signing + notarization. A DMG built on top
# of this will trip Gatekeeper on first open, so the user must right-click →
# Open (or strip the quarantine attribute). See the README "Download" section.
#
# Required environment:
#   APP_BUNDLE   absolute path to the .app bundle to sign
#   REPO_ROOT    absolute path to the repo root
#
# Optional environment:
#   ENTITLEMENTS  path to the entitlements plist (defaults to the staged file
#                 bundle-app.sh writes next to the .app).

set -euo pipefail

: "${APP_BUNDLE:?APP_BUNDLE must be set}"
: "${REPO_ROOT:?REPO_ROOT must be set}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: bundle not found at $APP_BUNDLE" >&2
    exit 1
fi

ENTITLEMENTS="${ENTITLEMENTS:-$(dirname "$APP_BUNDLE")/$(basename "${APP_BUNDLE%.app}").entitlements}"
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    echo "       (expected bundle-app.sh to stage it next to the .app)" >&2
    exit 1
fi

# Sign inner frameworks first (deepest-first), ad-hoc. No --options runtime:
# hardened runtime without notarization only invites library-validation kills
# on an ad-hoc identity, and buys nothing for an un-notarized build.
shopt -s nullglob
for framework in "$APP_BUNDLE/Contents/Frameworks/"*.framework; do
    echo "    ad-hoc signing framework: $(basename "$framework")"
    /usr/bin/codesign --force --sign - "$framework"
done
shopt -u nullglob

echo "    ad-hoc signing main bundle"
/usr/bin/codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

echo "    verifying signature"
/usr/bin/codesign --verify --verbose=2 "$APP_BUNDLE"

echo "    ad-hoc signed (NOT notarized): $APP_BUNDLE"
