#!/usr/bin/env bash
# scripts/export-local-signing-cert.sh
#
# Exports the local "Trace Local Signing" identity (certificate + private key)
# created by scripts/setup-local-signing.sh as a base64-encoded PKCS#12, so the
# SAME certificate can sign released DMGs in CI.
#
# WHY THIS MATTERS: macOS pins a TCC grant — especially "Screen & System Audio
# Recording" used for meeting capture — to the app's exact code signature, not its
# bundle id. If local builds and the CI-built DMG are signed with DIFFERENT certs
# (even sharing the name "Trace Local Signing"), installing one after granting the
# other silently kills the grant: the toggle still shows ON but the system-audio
# tap goes deaf and meetings record only you. Sharing one cert across local + CI
# is the fix.
#
# The export goes to a FILE under dist/ (gitignored), never the terminal — it
# contains a private key. After running, set the two GitHub secrets the
# release-unsigned workflow reads, cut a release, grant Trace once, then DELETE the
# exported files. All printed below.
#
# Usage:
#   scripts/export-local-signing-cert.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CERT_CN="Trace Local Signing"
KEYCHAIN="trace-signing.keychain"
KCPASS="trace-local-signing"
# The PKCS#12 passphrase doubles as LOCAL_SIGNING_CERT_PASSWORD in CI. Keep it
# equal to the keychain password so the workflow's default just works.
P12_PASS="${LOCAL_SIGNING_CERT_PASSWORD:-$KCPASS}"

OUT_DIR="$REPO_ROOT/dist"
OUT_P12="$OUT_DIR/trace-local-signing.p12"
OUT_B64="$OUT_DIR/trace-local-signing.p12.b64"

if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    echo "ERROR: '$CERT_CN' is not set up on this Mac." >&2
    echo "       Run scripts/setup-local-signing.sh first." >&2
    exit 1
fi

umask 077
mkdir -p "$OUT_DIR"
rm -f "$OUT_P12" "$OUT_B64"

echo "==> unlocking keychain + exporting identity (cert + private key)"
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"
# Allow Apple command-line tools to read the key non-interactively. If a GUI
# dialog still appears, click "Always Allow".
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null 2>&1 || true
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$P12_PASS" -o "$OUT_P12"
base64 < "$OUT_P12" > "$OUT_B64"
chmod 600 "$OUT_P12" "$OUT_B64"

LEAF="$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1/ {print $3; exit}')"

cat <<EOF

==> exported:
      $OUT_P12      (PKCS#12, passphrase: $P12_PASS)
      $OUT_B64  (base64, for the GitHub secret)
    cert leaf SHA-1: ${LEAF:-unknown}

Next steps (these touch your GitHub secrets — run them yourself):
  gh secret set LOCAL_SIGNING_CERT_P12 < "$OUT_B64"
  printf '%s' '$P12_PASS' | gh secret set LOCAL_SIGNING_CERT_PASSWORD

Then cut a release (scripts/ship.sh vX.Y.Z). The next DMG is signed with THIS
cert. Install it, grant Trace once under Screen & System Audio Recording, and the
grant sticks across every future local + CI build.

Finally, delete the key material (it can sign as Trace):
  rm "$OUT_P12" "$OUT_B64"
EOF
