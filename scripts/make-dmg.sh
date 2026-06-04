#!/usr/bin/env bash
# scripts/make-dmg.sh
#
# Builds a distributable .dmg containing Trace.app and an
# /Applications symlink, signed with the same Developer ID identity as
# the .app inside. Uses pure hdiutil (no create-dmg dependency) to keep
# the script self-contained and reproducible.
#
# Required environment:
#   APP_BUNDLE   absolute path to the .app to package
#   DIST_DIR     directory to write the DMG into
#   APP_NAME     "Trace"
#   VERSION      marketing version
#
# Optional environment:
#   DEVELOPER_ID_APPLICATION   identity hash for codesigning the DMG.
#                              Same auto-detection as sign-app.sh.

set -euo pipefail

: "${APP_BUNDLE:?APP_BUNDLE must be set}"
: "${DIST_DIR:?DIST_DIR must be set}"
: "${APP_NAME:?APP_NAME must be set}"
: "${VERSION:?VERSION must be set}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: bundle not found at $APP_BUNDLE" >&2
    exit 1
fi

DMG_OUT="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGE_DIR="$DIST_DIR/.dmg-stage"
VOLUME_NAME="$APP_NAME $VERSION"

echo "    cleaning previous DMG + staging"
rm -rf "$STAGE_DIR" "$DMG_OUT"
mkdir -p "$STAGE_DIR"

echo "    staging bundle and Applications symlink"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# A static .DS_Store with bespoke icon layout would normally live here; the
# brutalist visual identity rule (spec §6.5) forbids decorative chrome, so
# the DMG ships with default Finder layout. No custom .DS_Store.

echo "    sizing volume"
SIZE_KB="$(/usr/bin/du -sk "$STAGE_DIR" | /usr/bin/awk '{print $1}')"
# Pad with 50 MiB headroom for filesystem overhead.
SIZE_KB="$(( SIZE_KB + 51200 ))"

TMP_DMG="$DIST_DIR/.tmp-$APP_NAME-$VERSION.dmg"
rm -f "$TMP_DMG"

echo "    hdiutil create"
/usr/bin/hdiutil create \
    -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -o "$TMP_DMG"

echo "    converting to compressed read-only"
/usr/bin/hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_OUT"

rm -f "$TMP_DMG"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    DEVELOPER_ID_APPLICATION="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F\" '/Developer ID Application/ { gsub(/[[:space:]]+\(.*\)/, "", $2); print $2; exit }'
    )"
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "    signing DMG with $DEVELOPER_ID_APPLICATION"
    /usr/bin/codesign --force --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$DMG_OUT"
else
    echo "WARN: skipping DMG signing — no Developer ID identity available" >&2
fi

echo "    verifying DMG"
/usr/bin/hdiutil verify "$DMG_OUT" >/dev/null

rm -rf "$STAGE_DIR"

echo "    dmg: $DMG_OUT"
