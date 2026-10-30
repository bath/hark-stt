#!/usr/bin/env bash
# Builds a signed, notarized Hark.app and its disk image.
#
#   app/scripts/release.sh             sign with Developer ID, notarize, staple, make the DMG
#   app/scripts/release.sh --dry-run   the same with the local signing identity and no notarization
#   app/scripts/release.sh --upload    also attach the DMG to the GitHub release v<version>,
#                                      and set the cask's version and sha256 here and in bath/homebrew-tap
#
# Needs, unless --dry-run:
#   HARK_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   and one of:
#   HARK_NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials)
#   HARK_NOTARY_KEY, HARK_NOTARY_KEY_ID, HARK_NOTARY_ISSUER   an App Store Connect API key (.p8 path), for CI
#
# Prints the DMG path and its sha256.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --upload) UPLOAD=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/.*harkVersion = "\(.*\)".*/\1/p' "$APP_DIR/Sources/HarkCore/Version.swift")"
APP="$APP_DIR/build/Hark.app"
DMG="$APP_DIR/build/Hark-$VERSION.dmg"
ENTITLEMENTS="$APP_DIR/Resources/Hark.entitlements"

if [ "$DRY_RUN" = 0 ]; then
  case "${HARK_SIGN_IDENTITY:-}" in
    "Developer ID Application:"*) ;;
    *) echo "Set HARK_SIGN_IDENTITY to a \"Developer ID Application: …\" identity (or use --dry-run)." >&2; exit 1 ;;
  esac
  if [ -z "${HARK_NOTARY_PROFILE:-}" ] && [ -z "${HARK_NOTARY_KEY:-}" ]; then
    echo "Set HARK_NOTARY_PROFILE, or HARK_NOTARY_KEY, HARK_NOTARY_KEY_ID and HARK_NOTARY_ISSUER (or use --dry-run)." >&2
    exit 1
  fi
fi

notarize() {
  if [ -n "${HARK_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$HARK_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$HARK_NOTARY_KEY" --key-id "$HARK_NOTARY_KEY_ID" \
      --issuer "$HARK_NOTARY_ISSUER" --wait
  fi
}

echo "==> Build Hark $VERSION"
"$APP_DIR/scripts/build-app.sh"
IDENTITY="${HARK_SIGN_IDENTITY:-$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)}"
IDENTITY="${IDENTITY:--}"

echo "==> Sign with the hardened runtime ($IDENTITY)"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

if [ "$DRY_RUN" = 0 ]; then
  echo "==> Notarize the app"
  ZIP="$APP_DIR/build/Hark-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

echo "==> Disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Hark.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Hark" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$DRY_RUN" = 0 ]; then
  echo "==> Notarize the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [ "$UPLOAD" = 1 ]; then
  echo "==> Upload to the GitHub release v$VERSION"
  gh release upload "v$VERSION" "$DMG" --clobber

  echo "==> Cask: Casks/hark.rb here and in bath/homebrew-tap"
  CASK="$(dirname "$APP_DIR")/Casks/hark.rb"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  TAP_SHA="$(gh api repos/bath/homebrew-tap/contents/Casks/hark.rb --jq .sha 2>/dev/null || true)"
  gh api -X PUT repos/bath/homebrew-tap/contents/Casks/hark.rb \
    -f message="hark $VERSION (cask)" -f content="$(base64 <"$CASK")" ${TAP_SHA:+-f sha="$TAP_SHA"} >/dev/null
  echo "Commit Casks/hark.rb here, then run: brew update && brew audit --strict --cask bath/tap/hark"
fi

echo "$DMG"
echo "sha256 $SHA"
