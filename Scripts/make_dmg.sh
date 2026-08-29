#!/bin/bash
# Packs dist/Blurt.app into a DMG. Produces two identical files:
#   dist/Blurt.dmg          — stable name; the website's download button points
#                             at releases/latest/download/Blurt.dmg
#   dist/Blurt-<version>.dmg — versioned copy for the release archive
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Blurt.app"
[[ -d "$APP" ]] || { echo "Run Scripts/build.sh first — no $APP"; exit 1; }

# Release integrity gate: a DMG must carry a certificate-pinned designated
# requirement. An ad-hoc build gets a cdhash requirement instead, which resets
# every user's permission grants on update AND leaves a stale, lying entry in
# System Settings. Development can override explicitly; releases cannot ship
# it by accident.
if ! codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf"; then
  if [[ "${BLURT_ALLOW_ADHOC_DMG:-}" == "1" ]]; then
    echo "WARNING: packaging an ad-hoc build (BLURT_ALLOW_ADHOC_DMG=1)."
    echo "         Never publish this DMG — grants reset on every update."
  else
    echo "ERROR: $APP is not signed with a certificate-pinned requirement."
    echo "       Run 'make cert' once, then 'make build', and try again."
    echo "       (Dev-only escape hatch: BLURT_ALLOW_ADHOC_DMG=1 make dmg)"
    exit 1
  fi
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me First.txt" <<'TXT'
Blurt — free, local dictation for macOS
=======================================

Installing
----------
1. Drag Blurt onto the Applications folder shown here.
2. Open Applications and double-click Blurt.

macOS will refuse the first launch, because this is a community build rather
than an Apple-notarized one:

   Open System Settings → Privacy & Security, scroll down, and click
   "Open Anyway" next to the message about Blurt. Then open it again.

First run
---------
Blurt asks for two permissions and downloads its speech model (about a
about 480 MB, once). After that it works with no network at all.

  • Microphone    — to hear you.
  • Accessibility — to notice your dictation key and to paste for you.

Using it
--------
  • Tap the dictation key (Right Option by default): starts recording.
    Tap again: stops, transcribes, pastes.
  • Hold the key: records while you hold, stops when you let go.
  • Double-tap: toggles Gaze Mode (hands-free — look, talk, done).

Everything else lives in the menu bar icon → Open Dashboard.

Your audio never leaves this Mac. Recordings are written to disk while you
speak so a crash cannot lose what you said, and are deleted once transcribed
(you choose how long to keep them in the dashboard).

Source, issues, forks: https://github.com/alexandrespitz/blurt
TXT

echo "==> Building dist/Blurt.dmg"
rm -f "dist/Blurt.dmg" "dist/Blurt-$VERSION.dmg"
hdiutil create \
  -volname "Blurt" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "dist/Blurt.dmg" >/dev/null
cp "dist/Blurt.dmg" "dist/Blurt-$VERSION.dmg"

SIZE=$(du -h "dist/Blurt.dmg" | cut -f1)
SHA=$(shasum -a 256 "dist/Blurt.dmg" | awk '{print $1}')
echo "==> dist/Blurt.dmg ($SIZE)  +  dist/Blurt-$VERSION.dmg"
echo "    SHA-256: $SHA"
