#!/usr/bin/env bash
# scripts/notarize-app.sh
#
# Submits the signed Trace.app to Apple notarization via notarytool
# and staples the resulting ticket onto the bundle. Notarytool credentials
# live in a Keychain profile created once with:
#
#   xcrun notarytool store-credentials "trace-notary" \
#       --apple-id "<your-apple-id>" \
#       --team-id  "<10-char-team-id>" \
#       --password "<app-specific-password>"
#
# Required environment:
#   APP_BUNDLE   absolute path to the .app to notarize
#
# Optional environment:
#   NOTARYTOOL_PROFILE   name of the saved credentials profile
#                        (default: "trace-notary")
#   NOTARYTOOL_TIMEOUT   wait timeout for the submission, in seconds
#                        (default: 1800)

set -euo pipefail

: "${APP_BUNDLE:?APP_BUNDLE must be set}"

NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-trace-notary}"
NOTARYTOOL_TIMEOUT="${NOTARYTOOL_TIMEOUT:-1800}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: bundle not found at $APP_BUNDLE" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null; then
    echo "ERROR: xcrun not on PATH; install Xcode command line tools" >&2
    exit 2
fi

if ! xcrun --find notarytool >/dev/null 2>&1; then
    echo "ERROR: notarytool not found; requires Xcode 13+" >&2
    exit 2
fi

ZIP_PATH="${APP_BUNDLE%.app}-for-notarization.zip"
echo "    zipping bundle to $ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "    submitting to notarytool (profile=$NOTARYTOOL_PROFILE)"
if ! xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait \
    --timeout "$NOTARYTOOL_TIMEOUT"; then
    echo "ERROR: notarytool submission failed" >&2
    echo "       run: xcrun notarytool log <submission-id> --keychain-profile $NOTARYTOOL_PROFILE" >&2
    rm -f "$ZIP_PATH"
    exit 5
fi

echo "    stapling ticket onto $APP_BUNDLE"
if ! xcrun stapler staple "$APP_BUNDLE"; then
    echo "ERROR: stapler failed" >&2
    rm -f "$ZIP_PATH"
    exit 5
fi

echo "    Gatekeeper re-assessment after staple"
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"; then
    echo "ERROR: spctl rejected the stapled bundle" >&2
    rm -f "$ZIP_PATH"
    exit 5
fi

rm -f "$ZIP_PATH"
echo "    notarized + stapled: $APP_BUNDLE"
