#!/bin/bash
# Builds Blurt into dist/Blurt.app and signs it.
#
# Signing matters more than it looks: macOS remembers permission grants
# (Accessibility, microphone) against the app's signing identity. The build is
# signed with the "Blurt Dev" certificate and an explicit designated
# requirement pinned to that certificate — so every build presents the same
# identity, and grants survive rebuilds and updates. Run `make cert` once to
# mint the identity (Scripts/make_signing_cert.sh — no password prompts).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CLI_ONLY=false
[[ "${1:-}" == "--cli-only" ]] && CLI_ONLY=true

BUNDLE_ID="com.alexspitz.blurt"
CERT_NAME="${BLURT_CERT_NAME:-Blurt Dev}"

echo "==> Generating the Xcode project"
xcodegen generate --quiet

if $CLI_ONLY; then
  echo "==> Building blurt-cli"
  xcodebuild build \
    -project Blurt.xcodeproj \
    -scheme BlurtCLI \
    -configuration Debug \
    -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' \
    -quiet
  echo "==> Built build/Build/Products/Debug/blurt-cli"
  exit 0
fi

echo "==> Building Blurt (Release)"
xcodebuild build \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -configuration Release \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  -quiet

APP="build/Build/Products/Release/Blurt.app"
[[ -d "$APP" ]] || { echo "Build produced no app bundle at $APP"; exit 1; }

echo "==> Staging dist/Blurt.app"
rm -rf dist
mkdir -p dist
cp -R "$APP" dist/

# The identity lives in its own keychain (made by `make cert`) whose key has a
# prompt-free ACL — signing works from scripts and CI with no dialogs. It shows
# as "untrusted" in Keychain Access; that is fine: end users see "unidentified
# developer" either way, and the permission system pins to the explicit
# requirement below, not to display trust.
SIGN_KEYCHAIN="$HOME/.blurt-signing/blurt-signing.keychain-db"
if security find-certificate -c "$CERT_NAME" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
  echo "==> Signing with: $CERT_NAME"
  CERT_SHA1=$(security find-certificate -c "$CERT_NAME" -Z "$SIGN_KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1/ {print $3; exit}')
  [[ -n "$CERT_SHA1" ]] || { echo "ERROR: certificate hash not found"; exit 1; }
  # The alarm turns any keychain hang into a loud failure. Signing once
  # produced an ad-hoc app because exactly this hang was silently killed.
  perl -e 'alarm 30; exec @ARGV' codesign --force --deep \
    --sign "$CERT_NAME" --keychain "$SIGN_KEYCHAIN" --timestamp=none \
    --requirements "=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\"" \
    dist/Blurt.app || {
    echo "ERROR: signing failed or timed out."
    echo "       Run 'make cert' to (re)create the prompt-free signing keychain."
    echo "       Do NOT ship ad-hoc: permission grants reset on every build."
    exit 1
  }
else
  echo "==> No '$CERT_NAME' identity — signing ad-hoc."
  echo "    Run 'make cert' once to stop permission grants resetting per build."
  codesign --force --deep --sign "-" --timestamp=none dist/Blurt.app
fi

codesign -dv dist/Blurt.app 2>&1 | sed 's/^/    /'
codesign -d -r- dist/Blurt.app 2>&1 | grep designated | sed 's/^/    /'

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  dist/Blurt.app/Contents/Info.plist)
echo "==> Blurt $VERSION is ready at $ROOT/dist/Blurt.app"
