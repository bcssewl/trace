#!/usr/bin/env bash
# scripts/generate-appcast.sh
#
# Generates a Sparkle 2.x compliant appcast.xml for every .dmg present in
# dist/. The newest DMG (by mtime) is treated as the channel head. Each
# entry contains:
#   - sparkle:version (build number)
#   - sparkle:shortVersionString (marketing version)
#   - sparkle:minimumSystemVersion (LSMinimumSystemVersion from Info.plist)
#   - enclosure with length + sparkle:edSignature
#
# Required environment:
#   DIST_DIR     dist directory (defaults to <repo>/dist)
#   APP_NAME     bundle name
#
# Optional environment:
#   APPCAST_URL_PREFIX   base URL for enclosures (default: derived from
#                        the SUFeedURL value inside the latest .app bundle's
#                        Info.plist, with the filename stripped).
#
# Output:
#   $DIST_DIR/appcast.xml
#
# The script never embeds a private key. Signatures come from
# scripts/sparkle-sign.sh which reads the key from the user Keychain.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
APP_NAME="${APP_NAME:-Trace}"

if [[ ! -d "$DIST_DIR" ]]; then
    echo "ERROR: dist dir not found at $DIST_DIR" >&2
    exit 1
fi

shopt -s nullglob
DMGS=("$DIST_DIR/$APP_NAME"-*.dmg)
shopt -u nullglob

if [[ ${#DMGS[@]} -eq 0 ]]; then
    echo "ERROR: no DMGs found at $DIST_DIR/$APP_NAME-*.dmg" >&2
    exit 1
fi

# Determine appcast URL prefix.
DETECT_PLIST=""
if [[ -d "$DIST_DIR/$APP_NAME.app" ]]; then
    DETECT_PLIST="$DIST_DIR/$APP_NAME.app/Contents/Info.plist"
fi

if [[ -z "${APPCAST_URL_PREFIX:-}" && -f "$DETECT_PLIST" ]]; then
    if FEED="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$DETECT_PLIST" 2>/dev/null)"; then
        APPCAST_URL_PREFIX="${FEED%/*}"
    fi
fi

APPCAST_URL_PREFIX="${APPCAST_URL_PREFIX:-https://updates.example.com/releases}"

MIN_SYSTEM_VERSION="26.0"
if [[ -f "$DETECT_PLIST" ]]; then
    if PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$DETECT_PLIST" 2>/dev/null)"; then
        MIN_SYSTEM_VERSION="$PLIST_MIN"
    fi
fi

OUT="$DIST_DIR/appcast.xml"
echo "    writing appcast to $OUT"

{
    cat <<HEADER
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Trace</title>
        <link>${APPCAST_URL_PREFIX}/appcast.xml</link>
        <description>Trace release channel</description>
        <language>en</language>
HEADER
    for dmg in "${DMGS[@]}"; do
        base="$(basename "$dmg")"
        # Filename schema: Trace-<version>.dmg
        ver="${base#${APP_NAME}-}"
        ver="${ver%.dmg}"

        size_bytes="$(/usr/bin/stat -f '%z' "$dmg")"
        pub_date="$(/bin/date -r "$dmg" '+%a, %d %b %Y %H:%M:%S %z')"

        # Resolve EdDSA signature attributes.
        if ! sig_line="$("$REPO_ROOT/scripts/sparkle-sign.sh" "$dmg" 2>/dev/null)"; then
            echo "WARN: no signature for $base — appcast entry will be unsigned" >&2
            sig_line=""
        fi

        cat <<ITEM
        <item>
            <title>Trace $ver</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:version>${ver}</sparkle:version>
            <sparkle:shortVersionString>${ver}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <enclosure
                url="${APPCAST_URL_PREFIX}/${base}"
                type="application/octet-stream"
                length="${size_bytes}"
                ${sig_line} />
        </item>
ITEM
    done
    cat <<FOOTER
    </channel>
</rss>
FOOTER
} >"$OUT"

echo "    appcast: $OUT"
