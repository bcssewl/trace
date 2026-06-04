#!/usr/bin/env bash
# scripts/setup-local-signing.sh
#
# One-time setup of a STABLE, self-signed code-signing identity used to sign
# local personal builds of Trace (see scripts/build-local.sh). Because the
# identity is stable across rebuilds, macOS keeps the app's Microphone / Speech
# (TCC) permissions instead of re-prompting after every rebuild + reinstall.
#
# Needs NO Apple Developer account. LOCAL use only — other Macs do not trust
# this certificate, so it is useless for distribution. To ship a build other
# people can run, sign with a "Developer ID Application" identity and notarize.
#
# Safe to re-run: it recreates the keychain from scratch.
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

echo "==> (re)creating keychain $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

echo "==> importing identity + authorizing codesign (so signing never prompts)"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KCPASS" -A -T /usr/bin/codesign >/dev/null
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

echo "==> OK — '$CERT_CN' ready. Build with: scripts/build-local.sh --install"
