#!/bin/bash
# One-time setup: create a stable, self-signed code-signing identity so the app's
# signature stays constant across rebuilds. macOS ties privacy permissions (Full
# Disk Access, folder access) to the signature, so a stable identity means the
# grants persist instead of re-prompting on every build.
#
# This is a LOCAL DEV identity only. It is NOT trusted by Gatekeeper and does not
# replace notarization for distribution — it just stops the permission nagging on
# this machine. Everything it creates is easy to remove (see the bottom of this file).
set -euo pipefail

IDENTITY="StorageCleaner Local Signing"
KEYCHAIN="$HOME/Library/Keychains/storagecleaner-signing.keychain-db"
KCPASS="storagecleaner"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ Signing identity already exists: $IDENTITY"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Generating self-signed code-signing certificate…"
cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
# -legacy uses the older PKCS#12 encryption that macOS's `security import` can read
# (OpenSSL 3 defaults to AES-256, which fails to import). Fall back without it for
# LibreSSL, which doesn't know the flag but already uses a compatible cipher.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:sc -name "$IDENTITY" >/dev/null 2>&1 \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:sc -name "$IDENTITY" >/dev/null 2>&1

echo "▸ Creating dedicated signing keychain…"
if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$KCPASS" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

echo "▸ Importing certificate…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P sc -T /usr/bin/codesign >/dev/null 2>&1
# Let codesign use the private key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null 2>&1

# Add our keychain to the user search list (without dropping the existing ones).
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
if ! echo "$EXISTING" | grep -q "storagecleaner-signing"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo ""
# Note: `-v` (valid only) hides self-signed certs as "not trusted"; that's fine —
# codesign can still sign with it. So we check the full identity list instead.
security find-identity -p codesigning | grep -q "$IDENTITY" || {
  echo "✗ Identity not found after import." >&2; exit 1; }
echo "✓ Signing identity ready: $IDENTITY"
echo ""
echo "✓ Done. Build with:  ./Scripts/make-app.sh release"
echo ""
echo "To remove later:  security delete-keychain \"$KEYCHAIN\""
