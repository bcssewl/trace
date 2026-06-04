#!/usr/bin/env bash
#
# Recreate the stable self-signed code-signing identity the dev build uses
# (dev/project.yml → CODE_SIGN_IDENTITY: "TraceDevSigning").
#
# WHY THIS EXISTS
#   If that identity is missing or loses its private key, Xcode falls back to
#   ad-hoc signing — a brand-new code identity on every build. An unstable (or
#   post-build-modified, hence invalid) signature has no stable code identity,
#   so macOS cannot persistently honor "Always Allow" for the app's Keychain
#   items or TCC grants — you get re-prompted on every launch. This restores a
#   single, stable identity so one "Always Allow" sticks.
#
# Run once:  bash dev/recreate-dev-signing.sh   (then rebuild the dev app)
set -euo pipefail

NAME="TraceDevSigning"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Removing any orphaned '$NAME' certificate (e.g. one with no private key)…"
while security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null; do :; done

echo "▸ Generating a self-signed Code Signing certificate + private key…"
cat > "$TMP/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = TraceDevSigning
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" >/dev/null 2>&1

# OpenSSL 3.x writes a PKCS#12 with a SHA-256 integrity MAC and (for an empty
# password) a MAC macOS's `security import` cannot verify — it fails with
# "MAC verification failed during PKCS12 import (wrong password?)". Force the
# legacy SHA-1 MAC + 3DES PBE and use a non-empty passphrase; macOS accepts that.
# (`-legacy` enables OpenSSL 3's legacy provider for the 3DES PBE.)
P12_PASS="tracedev"
openssl pkcs12 -export -legacy -macalg sha1 \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "▸ Importing into the login keychain (codesign + all apps may use the key)…"
# -A lets any app use the key without the per-access partition-list prompt, which
# is what we want for a local dev signing key (avoids codesign prompting on each
# build). The cert stays self-signed/untrusted — that only affects verification,
# not the ability to sign (see dev/project.yml).
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign

echo
echo "✓ Done. Verify it's now present (self-signed → shows NOT_TRUSTED, which is"
echo "  fine; trust only affects verification, not signing):"
echo "    security find-identity -p codesigning | grep '$NAME'"
echo
echo "Next:"
echo "  1. Rebuild the dev app (Xcode ⌘R, or your usual dev build) so it's"
echo "     re-signed with this identity and the bundle seal is fresh."
echo "  2. Launch it and click 'Always Allow' once on the Keychain prompt."
echo
echo "If codesign still prompts for keychain access during a build, run once:"
echo "    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \\"
echo "        -k \"\$LOGIN_PASSWORD\" \"$KEYCHAIN\""
