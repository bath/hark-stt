#!/usr/bin/env bash
# Builds Hark.app into app/build/Hark.app.
#
#   app/scripts/build-app.sh
#
# Signs with $HARK_SIGN_IDENTITY, else the first "Apple Development"
# identity in the keychain (so macOS keeps the permissions across rebuilds),
# else ad hoc. scripts/release.sh signs for distribution.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(dirname "$APP_DIR")"
OUT="$APP_DIR/build/Hark.app"
SOUNDS="$APP_DIR/build/sounds"

swift build -c release --product Hark --package-path "$APP_DIR"
BIN="$(swift build -c release --show-bin-path --package-path "$APP_DIR")"
VERSION="$(sed -n 's/.*harkVersion = "\(.*\)".*/\1/p' "$APP_DIR/Sources/HarkCore/Version.swift")"

# The sound packs take a while to render, so keep them until generate.py changes.
if [ ! -f "$SOUNDS/packs.json" ] || [ "$ROOT/sounds/generate.py" -nt "$SOUNDS/packs.json" ]; then
  rm -rf "$SOUNDS"
  /usr/bin/python3 "$ROOT/sounds/generate.py" "$SOUNDS" >/dev/null
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$OUT/Contents/Resources"
cp "$BIN/Hark" "$OUT/Contents/MacOS/Hark"
install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/Contents/MacOS/Hark"
ditto "$BIN/whisper.framework" "$OUT/Contents/Frameworks/whisper.framework"
sed "s/__VERSION__/$VERSION/g" "$APP_DIR/Resources/Info.plist" >"$OUT/Contents/Info.plist"
ditto "$SOUNDS" "$OUT/Contents/Resources/sounds"
find "$APP_DIR/Resources" -type f ! -name Info.plist ! -name '*.entitlements' -exec cp {} "$OUT/Contents/Resources/" \;

IDENTITY="${HARK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$OUT/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$OUT"
echo "Built $OUT ($VERSION, signed by ${IDENTITY/#-/ad hoc})"
