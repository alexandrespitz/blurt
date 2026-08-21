#!/bin/bash
# Creates a self-signed code-signing identity called "Blurt Dev" inside a
# dedicated keychain, so signing works without a single password prompt —
# including from scripts and CI.
#
# Why bother without an Apple Developer account: macOS remembers permission
# grants (Accessibility, microphone) against the app's signing identity. A
# plain ad-hoc signature changes identity on every build, so grants reset each
# time. A stable certificate keeps them — across your rebuilds AND across app
# updates for anyone using your builds.
#
# The keychain lives outside the repo (never commit a private key). Forks run
# this once and get their own identity.
set -euo pipefail

NAME="${BLURT_CERT_NAME:-Blurt Dev}"
STORE="$HOME/.blurt-signing"
KEYCHAIN="$STORE/blurt-signing.keychain-db"
PASSFILE="$STORE/keychain-password"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The '$NAME' identity already exists — nothing to do."
  exit 0
fi

mkdir -p "$STORE"
chmod 700 "$STORE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$PASSFILE" ]]; then
  openssl rand -hex 24 > "$PASSFILE"
  chmod 600 "$PASSFILE"
fi
PASS=$(cat "$PASSFILE")

cat > "$TMP/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" 2>/dev/null

# Apple's keychain importer rejects OpenSSL 3's modern PKCS12 defaults,
# hence the explicitly legacy algorithms.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "==> Creating the dedicated signing keychain"
if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASS" "$KEYCHAIN"
fi
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock for this keychain only

echo "==> Importing the identity"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

# This is what lets codesign use the key without a GUI prompt — the exact
# step whose absence once made signing hang in headless shells.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "==> Adding the keychain to the search list"
KEYCHAINS=()
while IFS= read -r line; do
  entry=$(echo "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  [[ -n "$entry" && "$entry" != "$KEYCHAIN" ]] && KEYCHAINS+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${KEYCHAINS[@]}"

# No trust-settings step on purpose: registering trust pops a GUI
# authorization dialog, and codesign accepts the identity without it. The
# certificate shows as "untrusted" in Keychain Access; end users see an
# "unidentified developer" app either way.

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> Done. Scripts/build.sh will sign as '$NAME' from now on,"
  echo "    with no password prompts, ever."
else
  echo "==> Something went wrong — the identity did not register."
  exit 1
fi
