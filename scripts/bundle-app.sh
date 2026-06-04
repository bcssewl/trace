#!/usr/bin/env bash
# scripts/bundle-app.sh
#
# Wraps the SwiftPM release binary into dist/Trace.app with the layout:
#
#   Trace.app/
#     Contents/
#       Info.plist
#       MacOS/
#         Trace           (executable)
#       Resources/
#         AppIcon.icns
#         BootstrapConfig.json
#         SchemaV1.bundle/        (templates etc. — synthesized from SPM resource paths)
#       Frameworks/
#         Sparkle.framework/      (operator drops the release framework here)
#       _CodeSignature/           (populated by sign-app.sh)
#
# Required environment (build-app.sh sets these):
#   SOURCE_BIN   absolute path to the swift-built binary
#   REPO_ROOT    absolute path to the repo root
#   DIST_DIR     absolute path to the dist directory
#   APP_NAME     "Trace"
#   VERSION      marketing version
#   BUILD        build number
#
# Validations performed:
#   - Info.plist is rendered from Resources/Info.plist.in and passes plutil.
#   - The entitlements file is present and passes plutil.
#   - The binary actually exists and is executable.
#   - The bundle structure conforms to the canonical macOS application layout.

set -euo pipefail

: "${SOURCE_BIN:?SOURCE_BIN must be set by caller}"
: "${REPO_ROOT:?REPO_ROOT must be set by caller}"
: "${DIST_DIR:?DIST_DIR must be set by caller}"
: "${APP_NAME:=Trace}"
: "${VERSION:=0.0.0-dev}"
: "${BUILD:=0}"

if [[ ! -x "$SOURCE_BIN" ]]; then
    echo "ERROR: source binary not executable: $SOURCE_BIN" >&2
    exit 1
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

echo "    cleaning previous bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

echo "    copying binary"
cp -p "$SOURCE_BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# SwiftPM links Sparkle as @rpath/Sparkle.framework but only bakes an
# @loader_path rpath (which resolves against the build dir, not the bundle).
# Add the in-bundle search path so the embedded framework is found once the
# .app is moved/installed. Signing happens later, so editing load commands here
# is safe.
if ! /usr/bin/otool -l "$MACOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    echo "    adding @executable_path/../Frameworks rpath"
    /usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/$APP_NAME"
fi

echo "    rendering Info.plist"
export COPYRIGHT="Copyright $(date +%Y) Trace authors. All rights reserved."
# The update feed lives on the GitHub Releases "latest" alias, so the app always
# checks the newest published release. The public key matches the EdDSA private
# key held in the SPARKLE_ED_PRIVATE_KEY CI secret (override both via env if the
# signing key is ever rotated).
export SU_FEED_URL_RESOLVED="${SU_FEED_URL:-https://github.com/bcssewl/trace/releases/latest/download/appcast.xml}"
export SU_PUBLIC_ED_KEY_RESOLVED="${SU_PUBLIC_ED_KEY:-bOFYSnRDpIR99coVgJeQSJB8u7ofVXQzBPCOitXiOXU=}"

# Use a Python one-liner for portable substitution (sed has different
# semantics across BSD vs GNU; Python ships with macOS by default).
/usr/bin/python3 - "$REPO_ROOT/Resources/Info.plist.in" "$CONTENTS/Info.plist" <<PYEOF
import os, sys
src, dst = sys.argv[1], sys.argv[2]
mapping = {
    "@VERSION@":         os.environ["VERSION"],
    "@BUILD@":           os.environ["BUILD"],
    "@COPYRIGHT@":       os.environ.get("COPYRIGHT", ""),
    "@SU_FEED_URL@":     os.environ.get("SU_FEED_URL_RESOLVED", ""),
    "@SU_PUBLIC_ED_KEY@":os.environ.get("SU_PUBLIC_ED_KEY_RESOLVED", ""),
}
with open(src, "r", encoding="utf-8") as fh:
    body = fh.read()
for k, v in mapping.items():
    body = body.replace(k, v)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(body)
PYEOF

if ! /usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null; then
    echo "ERROR: rendered Info.plist failed plutil -lint" >&2
    exit 2
fi

echo "    staging entitlements (signing input only — never shipped inside the bundle)"
# Codesign consumes the entitlements as an input; a stray .entitlements file
# left inside Contents/ is treated as an unsigned subcomponent and trips
# `codesign --verify --deep --strict`. Stage it alongside the .app instead;
# sign-app.sh reads it from this location.
ENTITLEMENTS_STAGE="$DIST_DIR/$APP_NAME.entitlements"
cp -p "$REPO_ROOT/Resources/Trace.entitlements" "$ENTITLEMENTS_STAGE"
if ! /usr/bin/plutil -lint "$ENTITLEMENTS_STAGE" >/dev/null; then
    echo "ERROR: entitlements file failed plutil -lint" >&2
    exit 2
fi

echo "    copying BootstrapConfig.json"
cp -p "$REPO_ROOT/Resources/BootstrapConfig.json" "$RESOURCES/BootstrapConfig.json"

echo "    building AppIcon.icns"
ICONSET="$REPO_ROOT/Resources/AppIcon.iconset"
ICNS_OUT="$RESOURCES/AppIcon.icns"
if "$REPO_ROOT/scripts/make-icns.sh" --iconset "$ICONSET" --out "$ICNS_OUT"; then
    echo "    icon ready: $ICNS_OUT"
else
    echo "WARN: icon generation failed; bundle will lack AppIcon.icns" >&2
fi

echo "    copying SwiftPM resource bundles"
# SwiftPM copies module resources next to the executable as <Module>_<Resource>.bundle.
BIN_DIR="$(dirname "$SOURCE_BIN")"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    echo "      bundle: $(basename "$bundle")"
    cp -R "$bundle" "$RESOURCES/"
done
shopt -u nullglob

echo "    embedding Sparkle.framework (if available)"
SPARKLE_FRAMEWORK_PATH="${SPARKLE_FRAMEWORK_PATH:-}"
if [[ -z "$SPARKLE_FRAMEWORK_PATH" ]]; then
    for candidate in \
        "$(dirname "$SOURCE_BIN")/Sparkle.framework" \
        "$REPO_ROOT/Frameworks/Sparkle.framework" \
        "/Library/Frameworks/Sparkle.framework"; do
        if [[ -d "$candidate" ]]; then
            SPARKLE_FRAMEWORK_PATH="$candidate"
            break
        fi
    done
fi

if [[ -n "$SPARKLE_FRAMEWORK_PATH" && -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
    cp -R "$SPARKLE_FRAMEWORK_PATH" "$FRAMEWORKS/Sparkle.framework"
    echo "      framework copied from $SPARKLE_FRAMEWORK_PATH"
else
    echo "WARN: Sparkle.framework not found; auto-updates will be inert until a release build" >&2
    echo "      hint: drop Sparkle.framework into Frameworks/ or set SPARKLE_FRAMEWORK_PATH" >&2
fi

echo "    verifying bundle layout"
test -f "$CONTENTS/Info.plist"
test -x "$MACOS/$APP_NAME"
test -d "$RESOURCES"
test -d "$FRAMEWORKS"

echo "    bundled: $APP_BUNDLE"
