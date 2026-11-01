#!/usr/bin/env bash
# Renders app/Icon/AppIcon.svg to app/Resources/AppIcon.icns.
# Run it after you change the SVG, and commit both files. Needs rsvg-convert (brew install librsvg).
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
