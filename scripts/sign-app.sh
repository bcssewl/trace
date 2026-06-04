#!/usr/bin/env bash
# scripts/sign-app.sh
#
# Codesigns the bundled Trace.app with Developer ID Application,
# hardened runtime, and the entitlements declared in spec §12.2.
#
# Required environment:
#   APP_BUNDLE   absolute path to the .app bundle to sign
#   REPO_ROOT    absolute path to the repo root
#
# Optional environment:
#   DEVELOPER_ID_APPLICATION   identity hash. If unset, the first
#                              "Developer ID Application" identity returned
#                              by `security find-identity -v -p codesigning`
#                              is used.
#   CODESIGN_TIMESTAMP         "1" (default) or "0" (disable Apple timestamp).

set -euo pipefail

: "${APP_BUNDLE:?APP_BUNDLE must be set}"
: "${REPO_ROOT:?REPO_ROOT must be set}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: bundle not found at $APP_BUNDLE" >&2
    exit 1
fi

# Entitlements are a signing input staged alongside the .app by bundle-app.sh
# (deliberately NOT inside Contents/, which would break --deep --strict verify).
# Override with the ENTITLEMENTS env var if needed.
ENTITLEMENTS="${ENTITLEMENTS:-$(dirname "$APP_BUNDLE")/$(basename "${APP_BUNDLE%.app}").entitlements}"
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    echo "       (expected bundle-app.sh to stage it next to the .app)" >&2
    exit 1
fi

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "    no DEVELOPER_ID_APPLICATION set; auto-detecting from Keychain"
    DEVELOPER_ID_APPLICATION="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F\" '/Developer ID Application/ { gsub(/[[:space:]]+\(.*\)/, "", $2); print $2; exit }'
    )"
    if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
        echo "ERROR: no Developer ID Application identity found in Keychain" >&2
        echo "       install one via Xcode > Settings > Accounts" >&2
        exit 4
    fi
fi

echo "    identity: $DEVELOPER_ID_APPLICATION"

TIMESTAMP_FLAG="--timestamp"
if [[ "${CODESIGN_TIMESTAMP:-1}" == "0" ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
fi

# Sign inner frameworks first (deepest-first traversal).
shopt -s nullglob
for framework in "$APP_BUNDLE/Contents/Frameworks/"*.framework; do
    echo "    signing framework: $(basename "$framework")"
    /usr/bin/codesign --force \
        --options runtime \
        $TIMESTAMP_FLAG \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$framework"
done
shopt -u nullglob

echo "    signing main bundle"
/usr/bin/codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    $TIMESTAMP_FLAG \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP_BUNDLE"

echo "    verifying signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "    verifying hardened runtime entitlement"
ENT_OUT="$(/usr/bin/codesign --display --entitlements - "$APP_BUNDLE" 2>/dev/null || true)"
for required in \
    "com.apple.security.cs.disable-library-validation" \
    "com.apple.security.device.audio-input" \
    "com.apple.security.automation.apple-events"; do
    if ! grep -q "$required" <<<"$ENT_OUT"; then
        echo "ERROR: required entitlement missing after sign: $required" >&2
        exit 4
    fi
done

echo "    spctl assessment (notarization not yet applied, expect rejection without staple)"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || true

echo "    signed: $APP_BUNDLE"
