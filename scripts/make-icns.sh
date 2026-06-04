#!/usr/bin/env bash
# scripts/make-icns.sh
#
# Builds AppIcon.icns from an .iconset directory using `iconutil`. When
# the iconset is empty (no real designer asset has been dropped in yet)
# the script renders a brutalist flat tile in 10 required sizes from a
# single 1024x1024 source PNG using `sips`. This keeps the release
# pipeline runnable even without a finished icon, but never falls back
# to a decorated, generic-AI placeholder.
#
# Usage:
#   scripts/make-icns.sh --iconset <dir> --out <path>
#
# The flat-tile placeholder uses a single solid color (#202024 — the
# brutalist neutral declared in spec §6.5) — no logo, no text, no emoji,
# nothing that could be mistaken for the production identity.

set -euo pipefail

ICONSET=""
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iconset) ICONSET="$2"; shift 2 ;;
        --out)     OUT="$2";     shift 2 ;;
        *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ICONSET" || -z "$OUT" ]]; then
    echo "ERROR: --iconset and --out are required" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null; then
    echo "ERROR: iconutil missing; install Xcode CLT" >&2
    exit 2
fi

REQUIRED_SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

mkdir -p "$ICONSET"

# Render placeholders for any missing required file.
TMP_BASE=""
for entry in "${REQUIRED_SIZES[@]}"; do
    name="${entry%%:*}"
    px="${entry##*:}"
    target="$ICONSET/$name"
    if [[ -f "$target" ]]; then
        continue
    fi
    if [[ -z "$TMP_BASE" ]]; then
        TMP_BASE="$(mktemp -t trace-icon).png"
        echo "    rendering placeholder base tile -> $TMP_BASE"
        # /usr/bin/sips can't synthesize a solid color image directly. We
        # generate a 1px PNG via printf into a base64 buffer, then upscale.
        /usr/bin/python3 - "$TMP_BASE" <<'PYEOF'
import struct, sys, zlib

def png(out, w, h, rgb):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag +
                data + struct.pack(">I", zlib.crc32(tag + data)))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    idat = zlib.compress(raw, 9)
    out_bytes = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(out, "wb") as fh:
        fh.write(out_bytes)

# brutalist neutral background: #202024
png(sys.argv[1], 1024, 1024, (0x20, 0x20, 0x24))
PYEOF
    fi
    echo "    scaling placeholder -> $name (${px}x${px})"
    /usr/bin/sips -z "$px" "$px" "$TMP_BASE" --out "$target" >/dev/null
done

if [[ -n "$TMP_BASE" ]]; then
    rm -f "$TMP_BASE"
fi

echo "    building $OUT from $ICONSET"
mkdir -p "$(dirname "$OUT")"
/usr/bin/iconutil --convert icns --output "$OUT" "$ICONSET"
