#!/usr/bin/env bash
# scripts/build-app.sh
#
# Top-level orchestrator for the Trace build & distribution pipeline.
# Wraps swift build, bundles the binary into a .app, optionally signs,
# notarizes, and packages into a DMG with an embedded Sparkle appcast entry.
#
# Usage:
#   scripts/build-app.sh [--version X.Y.Z] [--build N]
#                        [--skip-sign] [--skip-notarize] [--skip-dmg]
#                        [--skip-sparkle]
#
# Inputs (all optional; sensible defaults applied):
#   --version           Marketing version baked into CFBundleShortVersionString.
#                       Defaults to `git describe --tags --dirty` stripped of
#                       a leading "v", falling back to "0.0.0-dev".
#   --build             Build number baked into CFBundleVersion. Defaults to
#                       the commit count on HEAD (`git rev-list --count HEAD`).
#   --skip-sign         Stop after bundling. Useful for local debug runs.
#   --skip-notarize     Sign but do not submit to Apple notarization.
#   --skip-dmg          Stop after notarization (no DMG created).
#   --skip-sparkle      Skip appcast generation + EdDSA signing.
#   --adhoc             Free, no-Apple-account path: bundle, AD-HOC sign (the
#                       minimum for the app to launch on Apple Silicon), and
#                       package an unsigned DMG. Skips Developer ID signing,
#                       notarization, and the Sparkle appcast. The resulting DMG
#                       trips Gatekeeper on first open (right-click → Open).
#
# Secrets (read from environment, never hard-coded):
#   DEVELOPER_ID_APPLICATION  Identity hash for codesign (40-char hex).
#                             If empty, the script picks the first
#                             "Developer ID Application" from the user keychain.
#   NOTARYTOOL_PROFILE        Name of the notarytool keychain profile.
#                             Default: "trace-notary".
#   SPARKLE_KEYCHAIN_ACCOUNT  Generic-password account holding the EdDSA
#                             private key. Default: "sparkle.ed25519".
#   SPARKLE_KEYCHAIN_SERVICE  Service identifier. Default: "app.trace".
#
# Exit codes:
#   0   on success.
#   1   on usage error.
#   2   on missing tool (codesign, notarytool, hdiutil, sign_update, etc.).
#   3   on swift build failure.
#   4   on signing failure.
#   5   on notarization failure.
#   6   on DMG creation failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCRIPTS_DIR="$REPO_ROOT/scripts"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="Trace"
BUNDLE_ID="app.trace"

VERSION=""
BUILD=""
SKIP_SIGN=0
SKIP_NOTARIZE=0
SKIP_DMG=0
SKIP_SPARKLE=0
ADHOC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        VERSION="$2"; shift 2 ;;
        --build)          BUILD="$2";   shift 2 ;;
        --skip-sign)      SKIP_SIGN=1;     shift ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        --skip-dmg)       SKIP_DMG=1;      shift ;;
        --skip-sparkle)   SKIP_SPARKLE=1;  shift ;;
        --adhoc)          ADHOC=1;         shift ;;
        -h|--help)
            sed -n '3,40p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    if VERSION="$(git describe --tags --dirty 2>/dev/null)"; then
        VERSION="${VERSION#v}"
    else
        VERSION="0.0.0-dev"
    fi
fi

if [[ -z "$BUILD" ]]; then
    BUILD="$(git rev-list --count HEAD 2>/dev/null || echo "0")"
fi

export VERSION BUILD APP_NAME BUNDLE_ID DIST_DIR REPO_ROOT

echo "==> Trace build pipeline"
echo "    version : $VERSION"
echo "    build   : $BUILD"
echo "    dist    : $DIST_DIR"

mkdir -p "$DIST_DIR"

echo "==> [1/6] swift build -c release"
if ! swift build -c release; then
    echo "ERROR: swift build failed" >&2
    exit 3
fi

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: built binary not found at $BIN_PATH" >&2
    exit 3
fi

echo "==> [2/6] bundle .app"
SOURCE_BIN="$BIN_PATH" "$SCRIPTS_DIR/bundle-app.sh"

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# Free, no-Apple-account path: ad-hoc sign + package an unsigned DMG, then stop.
# (Distinct from --skip-sign, which exits before the DMG step.)
if [[ "$ADHOC" -eq 1 ]]; then
    echo "==> [3/4] ad-hoc sign (no Developer ID / notarization)"
    APP_BUNDLE="$APP_BUNDLE" "$SCRIPTS_DIR/sign-app-adhoc.sh"
    echo "==> [4/4] make unsigned DMG"
    APP_BUNDLE="$APP_BUNDLE" "$SCRIPTS_DIR/make-dmg.sh"
    echo "==> SUCCESS (unsigned)"
    echo "    app : $APP_BUNDLE"
    echo "    dmg : $DIST_DIR/$APP_NAME-$VERSION.dmg"
    echo "    note: unsigned — users must right-click → Open on first launch."
    exit 0
fi

if [[ "$SKIP_SIGN" -eq 1 ]]; then
    echo "==> --skip-sign: bundling complete, exiting at $APP_BUNDLE"
    exit 0
fi

echo "==> [3/6] codesign + hardened runtime"
APP_BUNDLE="$APP_BUNDLE" "$SCRIPTS_DIR/sign-app.sh"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "==> --skip-notarize: signing complete"
else
    echo "==> [4/6] notarize + staple"
    APP_BUNDLE="$APP_BUNDLE" "$SCRIPTS_DIR/notarize-app.sh"
fi

if [[ "$SKIP_DMG" -eq 1 ]]; then
    echo "==> --skip-dmg: stopping before DMG creation"
    exit 0
fi

echo "==> [5/6] make DMG"
APP_BUNDLE="$APP_BUNDLE" "$SCRIPTS_DIR/make-dmg.sh"

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

if [[ "$SKIP_SPARKLE" -eq 1 ]]; then
    echo "==> --skip-sparkle: appcast not regenerated"
else
    echo "==> [6/6] generate Sparkle appcast"
    DMG_PATH="$DMG_PATH" "$SCRIPTS_DIR/generate-appcast.sh"
fi

echo "==> SUCCESS"
echo "    app : $APP_BUNDLE"
echo "    dmg : $DMG_PATH"
