#!/bin/bash
# Renders the app icon: a rounded gradient tile with a microphone glyph,
# expanded into the sizes macOS wants and packed into an .icns.
set -euo pipefail

cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Rendering the master image"
swift Scripts/render_icon.swift "$TMP/icon_1024.png"

echo "==> Building the iconset"
SET="$TMP/Blurt.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon_1024.png" \
    --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "==> Wrote Resources/AppIcon.icns"
