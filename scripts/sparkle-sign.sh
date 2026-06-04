#!/usr/bin/env bash
# scripts/sparkle-sign.sh
#
# EdDSA-signs a single release artifact with the Sparkle 2.x sign_update
# helper. The private key is read from the user's login Keychain so it
# never lives on disk inside the repo.
#
# Usage:
#   scripts/sparkle-sign.sh <path-to-dmg-or-zip>          # prints attributes
#   scripts/sparkle-sign.sh --generate-key                # writes a new key
#   scripts/sparkle-sign.sh --print-public-key            # prints stored pubkey
#
# Storing the key (one-time setup; pseudo-shell):
#
#   # Generate the pair with sign_update --generate-keys, then:
#   security add-generic-password \
#       -a "${SPARKLE_KEYCHAIN_ACCOUNT:-sparkle.ed25519}" \
#       -s "${SPARKLE_KEYCHAIN_SERVICE:-app.trace}" \
#       -w "<base64-private-key>"
#
# The output is suitable to paste into the Sparkle appcast <enclosure>
# element. Format:
#   sparkle:edSignature="<base64>" length="<bytes>"
#
# Required environment (optional, with sensible defaults):
#   SPARKLE_KEYCHAIN_ACCOUNT   default "sparkle.ed25519"
#   SPARKLE_KEYCHAIN_SERVICE   default "app.trace"
#   SIGN_UPDATE                explicit path to sign_update if not on PATH

set -euo pipefail

SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-sparkle.ed25519}"
SPARKLE_KEYCHAIN_SERVICE="${SPARKLE_KEYCHAIN_SERVICE:-app.trace}"

resolve_sign_update() {
    if [[ -n "${SIGN_UPDATE:-}" && -x "$SIGN_UPDATE" ]]; then
        printf '%s' "$SIGN_UPDATE"
        return 0
    fi
    if command -v sign_update >/dev/null; then
        command -v sign_update
        return 0
    fi
    for candidate in \
        "/Library/Frameworks/Sparkle.framework/Versions/B/Resources/sign_update" \
        "/Library/Frameworks/Sparkle.framework/Resources/sign_update" \
        "$HOME/Library/Caches/org.swift.swiftpm/sparkle/sign_update"; do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

read_private_key() {
    security find-generic-password \
        -a "$SPARKLE_KEYCHAIN_ACCOUNT" \
        -s "$SPARKLE_KEYCHAIN_SERVICE" \
        -w 2>/dev/null
}

case "${1:-}" in
    "")
        echo "ERROR: usage: scripts/sparkle-sign.sh <path-to-release-artifact>" >&2
        exit 1
        ;;
    --generate-key)
        if ! SIGN_UPDATE_BIN="$(resolve_sign_update)"; then
            echo "ERROR: sign_update not found; install Sparkle 2.7+" >&2
            exit 2
        fi
        echo "    generating new EdDSA keypair"
        "$SIGN_UPDATE_BIN" --generate-keys
        echo "    add the printed PRIVATE key to your Keychain:"
        echo "      security add-generic-password \\"
        echo "          -a $SPARKLE_KEYCHAIN_ACCOUNT \\"
        echo "          -s $SPARKLE_KEYCHAIN_SERVICE \\"
        echo "          -w '<paste-base64-private-key>'"
        echo "    put the PUBLIC key into Resources/BootstrapConfig.json + Info.plist.in (SUPublicEDKey)"
        exit 0
        ;;
    --print-public-key)
        if ! SIGN_UPDATE_BIN="$(resolve_sign_update)"; then
            echo "ERROR: sign_update not found" >&2
            exit 2
        fi
        if ! PRIV="$(read_private_key)"; then
            echo "ERROR: no private key in keychain at $SPARKLE_KEYCHAIN_SERVICE/$SPARKLE_KEYCHAIN_ACCOUNT" >&2
            exit 3
        fi
        echo "$PRIV" | "$SIGN_UPDATE_BIN" --print-public-key
        exit 0
        ;;
esac

ARTIFACT="$1"
if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found: $ARTIFACT" >&2
    exit 1
fi

if ! SIGN_UPDATE_BIN="$(resolve_sign_update)"; then
    echo "ERROR: sign_update not found; install Sparkle 2.7+ release or set SIGN_UPDATE" >&2
    exit 2
fi

if ! PRIV="$(read_private_key)"; then
    echo "ERROR: no EdDSA private key in Keychain at" >&2
    echo "       service=$SPARKLE_KEYCHAIN_SERVICE account=$SPARKLE_KEYCHAIN_ACCOUNT" >&2
    echo "       run: scripts/sparkle-sign.sh --generate-key (one-time)" >&2
    exit 3
fi

# sign_update accepts the private key from an env var or stdin; using
# stdin avoids leaking the key into the process listing.
echo "$PRIV" | "$SIGN_UPDATE_BIN" -s - "$ARTIFACT"
