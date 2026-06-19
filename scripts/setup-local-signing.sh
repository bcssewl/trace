#!/usr/bin/env bash
# scripts/setup-local-signing.sh
#
# One-time setup of a STABLE, self-signed code-signing identity used to sign
# local personal builds of Trace (see scripts/build-local.sh). Because the
# identity is stable across rebuilds, macOS keeps the app's Microphone / Speech /
# System Audio (TCC) permissions instead of re-prompting after every rebuild +
# reinstall.
#
# IMPORTANT — share ONE cert with CI: macOS pins a TCC grant (especially the
# "Screen & System Audio Recording" one used for meeting capture) to the app's
# exact code signature, not just its bundle id. If local builds and the CI-built
# DMG are signed with DIFFERENT certs — even with the same name — installing one
# after granting the other silently kills the grant: the toggle still shows ON
# but the system-audio tap goes deaf and meetings record only you. So the local
# cert and the CI `LOCAL_SIGNING_CERT_P12` secret MUST be the same certificate:
#   First machine:  run with no args to GENERATE a cert, then
#                   scripts/export-local-signing-cert.sh to push it to CI.
#   Other machines: run with --from-p12 <path> to IMPORT that same cert, so every
#                   copy of Trace you ever run shares one signature.
#
# Needs NO Apple Developer account. LOCAL use only — other Macs do not trust this
# certificate, so it is useless for distribution. To ship a build other people can
# run, sign with a "Developer ID Application" identity and notarize.
#
# Safe to re-run: it recreates the keychain from scratch.
#
# Usage:
#   scripts/setup-local-signing.sh                       # generate a fresh cert
#   scripts/setup-local-signing.sh --from-p12 cert.p12   # import a shared cert
#   scripts/setup-local-signing.sh --from-p12 cert.p12 --p12-pass <pass>
#
# Creates:
#   - dedicated keychain  ~/Library/Keychains/trace-signing.keychain-db
#   - self-signed cert    CN="Trace Local Signing"  (valid 10 years)
# and adds the keychain to your user search list so codesign can find it.

set -euo pipefail

CERT_CN="Trace Local Signing"
KEYCHAIN="trace-signing.keychain"
# Throwaway password: this keychain holds only a meaningless self-signed cert
# that is worthless on any other machine, so the password is not a secret.
KCPASS="trace-local-signing"

FROM_P12=""
P12_PASS="$KCPASS"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-p12) FROM_P12="$2"; shift 2 ;;
        --p12-pass) P12_PASS="$2"; shift 2 ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "ERROR: unknown flag: $1" >&2; exit 1 ;;
    esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$FROM_P12" ]]; then
    if [[ ! -f "$FROM_P12" ]]; then
        echo "ERROR: --from-p12 file not found: $FROM_P12" >&2
        exit 1
    fi
    echo "==> importing shared identity from $FROM_P12"
    ID_P12="$FROM_P12"
    IMPORT_PASS="$P12_PASS"
else
    echo "==> generating self-signed code-signing certificate"
    cat > "$TMP/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Trace Local Signing
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

    # NOTE: the PKCS#12 export password MUST be non-empty — `security import`
    # silently imports zero keys from an empty-password .p12 (no error, but
    # `find-identity` then shows nothing and signing fails with "no identity found").
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:"$KCPASS" -name "$CERT_CN" 2>/dev/null
    ID_P12="$TMP/id.p12"
    IMPORT_PASS="$KCPASS"
fi

echo "==> (re)creating keychain $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

echo "==> importing identity + authorizing codesign/security (so signing + export never prompt)"
# -T codesign: signing never prompts. -T security: scripts/export-local-signing-cert.sh
# can re-export the key non-interactively to share it with CI.
security import "$ID_P12" -k "$KEYCHAIN" -P "$IMPORT_PASS" -A \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> adding keychain to the user search list (preserving existing, absolute paths)"
# IMPORTANT: pass full -db paths via a quoted array. Round-tripping the existing
# list through sed + unquoted word-splitting can mangle an entry (it once
# corrupted the login keychain path to "login.keychain-db -db"), silently
# dropping the login keychain from the search list.
KCPATH="$HOME/Library/Keychains/trace-signing.keychain-db"
declare -a SEARCH=("$KCPATH")
while IFS= read -r kc; do
    [ -n "$kc" ] && [ "$kc" != "$KCPATH" ] && SEARCH+=("$kc")
done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')
security list-keychains -d user -s "${SEARCH[@]}"

echo "==> smoke test (self-signed cert is reported NOT_TRUSTED; that is expected"
echo "    and only matters for verification/Gatekeeper, never for signing)"
cp /bin/echo "$TMP/cs-test"
codesign --force --options runtime --sign "$CERT_CN" "$TMP/cs-test"
codesign --verify --strict "$TMP/cs-test"

# The leaf SHA-1 is what macOS pins TCC grants to. It MUST match the cert CI signs
# with (and the cert your granted /Applications copy carries) or the system-audio
# grant won't survive switching between local and released builds.
LEAF="$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1/ {print $3; exit}')"
echo "==> OK — '$CERT_CN' ready. Cert leaf SHA-1: ${LEAF:-unknown}"
echo "    Build with: scripts/build-local.sh --install"
if [[ -z "$FROM_P12" ]]; then
    echo "    Share this SAME cert with CI so released DMGs match your local builds:"
    echo "        scripts/export-local-signing-cert.sh"
fi
