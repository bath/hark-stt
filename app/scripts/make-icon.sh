#!/usr/bin/env bash
# Renders app/Icon/AppIcon.svg to app/Resources/AppIcon.icns, and the disk
# image background app/dmg/background.svg to background.tiff (1x and 2x).
# Run it after you change an SVG, and commit the SVG and what it renders. Needs rsvg-convert (brew install librsvg).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$APP_DIR/Icon/AppIcon.svg"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SVG" -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o "$APP_DIR/Resources/AppIcon.icns"
rm -rf "$(dirname "$SET")"
echo "Wrote $APP_DIR/Resources/AppIcon.icns"

BG="$APP_DIR/dmg"
TMP="$(mktemp -d)"
rsvg-convert -w 640 -h 420 "$BG/background.svg" -o "$TMP/background.png"
rsvg-convert -w 1280 -h 840 "$BG/background.svg" -o "$TMP/background@2x.png"
tiffutil -cathidpicheck "$TMP/background.png" "$TMP/background@2x.png" -out "$BG/background.tiff" 2>/dev/null
rm -rf "$TMP"
echo "Wrote $BG/background.tiff"
