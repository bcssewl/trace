#!/usr/bin/env bash
# scripts/build-local.sh
#
# Build Trace.app for LOCAL personal use and (optionally) install it to
# /Applications, signed with the stable self-signed "Trace Local Signing"
# identity created by scripts/setup-local-signing.sh. The stable identity is
# what lets macOS keep your Microphone / Speech permissions across rebuilds.
#
# NOT for distribution (other Macs don't trust this cert). For a build other
# people can run without Gatekeeper warnings, sign with a Developer ID +
# notarize (see scripts/build-app.sh and scripts/notarize-app.sh).
#
# Usage:
#   scripts/build-local.sh                    # build only -> dist/Trace.app + .dmg
#   scripts/build-local.sh --install          # also install + relaunch /Applications/Trace.app
#   scripts/build-local.sh --version 0.2.0 --install

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CERT="Trace Local Signing"
KEYCHAIN="trace-signing.keychain"
KCPASS="trace-local-signing"
VERSION="0.1.0"
INSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --install) INSTALL=1;    shift ;;
        -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "ERROR: unknown flag: $1" >&2; exit 1 ;;
    esac
done

if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    echo "ERROR: '$CERT' is not set up yet." >&2
    echo "       Run the one-time setup first: scripts/setup-local-signing.sh" >&2
    exit 1
fi

# The signing keychain has no auto-lock timeout but still re-locks after a
# reboot, so unlock it before every build.
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

# Sparkle.framework lives next to the release binary; pass it explicitly so the
# bundler embeds it regardless of where else it might look.
SPARKLE="$(swift build -c release --show-bin-path)/Sparkle.framework"

DEVELOPER_ID_APPLICATION="$CERT" CODESIGN_TIMESTAMP=0 SPARKLE_FRAMEWORK_PATH="$SPARKLE" \
    scripts/build-app.sh --version "$VERSION" --skip-notarize --skip-sparkle

if [[ "$INSTALL" -eq 1 ]]; then
    echo "==> installing to /Applications + relaunching"
    pkill -x Trace 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Trace.app
    cp -R "$REPO_ROOT/dist/Trace.app" /Applications/Trace.app
    xattr -dr com.apple.quarantine /Applications/Trace.app 2>/dev/null || true
    open /Applications/Trace.app
    echo "==> /Applications/Trace.app installed + launched"
fi
