#!/usr/bin/env bash
# Builds a signed, notarized Hark.app and its disk image.
#
#   app/scripts/release.sh             sign with Developer ID, notarize, staple, make the DMG
#   app/scripts/release.sh --dry-run   the same with the local signing identity and no notarization
#   app/scripts/release.sh --upload    also attach the DMG to the GitHub release v<version>,
#                                      and set the cask's version and sha256 here and in bath/homebrew-tap
#   --no-tap                           with --upload: leave bath/homebrew-tap alone (CI updates it over SSH)
#
# Needs, unless --dry-run:
#   HARK_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   and one of:
#   HARK_NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials)
#   HARK_NOTARY_KEY, HARK_NOTARY_KEY_ID, HARK_NOTARY_ISSUER   an App Store Connect API key (.p8 path), for CI
#
# --upload also signs the DMG for Sparkle and writes docs/appcast.xml, which
# hark.works serves and the app reads to update itself. The Sparkle key is
# SPARKLE_PRIVATE_KEY (the text that `generate_keys -x FILE` exports), or the
# key in the login keychain when that is not set.
#
# Prints the DMG path and its sha256.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
UPLOAD=0
TAP=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --upload) UPLOAD=1 ;;
    --no-tap) TAP=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/.*harkVersion = "\(.*\)".*/\1/p' "$APP_DIR/Sources/HarkCore/Version.swift")"
APP="$APP_DIR/build/Hark.app"
DMG="$APP_DIR/build/Hark-$VERSION.dmg"
ENTITLEMENTS="$APP_DIR/Resources/Hark.entitlements"

# An app with no Sparkle key can never update itself, so do not release one.
if grep -q "__SPARKLE_PUBLIC_KEY__" "$APP_DIR/Resources/Info.plist" && [ "$DRY_RUN" = 0 ]; then
  echo "Set SUPublicEDKey in app/Resources/Info.plist to the Sparkle public key (see AGENTS.md, Release)." >&2
  exit 1
fi

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
"$APP_DIR/scripts/sign-nested.sh" "$APP" "$IDENTITY" --timestamp --options runtime
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
# dmgbuild writes the Finder window (background, icon places) without Finder,
# so this also works on a CI runner.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# dmgbuild 1.6.7 is the first version whose background shows on macOS 26.2 and
# later (dmgbuild#273). It needs Python 3.10 or later; Xcode's python3 is 3.9.
PY=""
for c in python3.14 python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 python3; do
  if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    PY="$c"; break
  fi
done
[[ -n "$PY" ]] || { echo "error: dmgbuild needs Python 3.10 or later (brew install python)" >&2; exit 1; }
"$PY" -m venv "$STAGE/venv"
"$STAGE/venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
rm -f "$DMG"
"$STAGE/venv/bin/dmgbuild" -s "$APP_DIR/dmg/settings.py" \
  -D app="$APP" -D background="$APP_DIR/dmg/background.tiff" \
  -D volume_icon="$APP_DIR/Resources/AppIcon.icns" "Hark" "$DMG" >/dev/null
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

  echo "==> Appcast: docs/appcast.xml"
  SIGN_UPDATE="$APP_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    KEY_FILE="$STAGE/sparkle.key"
    install -m 600 /dev/null "$KEY_FILE"
    printf '%s' "$SPARKLE_PRIVATE_KEY" >"$KEY_FILE"
    ED_SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" -p "$DMG")"
    rm -f "$KEY_FILE"
  else
    ED_SIGNATURE="$("$SIGN_UPDATE" -p "$DMG")"
  fi
  [ -n "$ED_SIGNATURE" ] || { echo "error: sign_update gave no signature" >&2; exit 1; }
  # One item: the latest release. Sparkle needs no older ones.
  cat >"$(dirname "$APP_DIR")/docs/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hark</title>
    <link>https://hark.works/appcast.xml</link>
    <item>
      <title>Hark $VERSION</title>
      <link>https://github.com/bath/hark-stt/releases/tag/v$VERSION</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/bath/hark-stt/releases/download/v$VERSION/Hark-$VERSION.dmg" sparkle:edSignature="$ED_SIGNATURE" length="$(stat -f %z "$DMG")" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

  echo "==> Cask: Casks/hark.rb"
  CASK="$(dirname "$APP_DIR")/Casks/hark.rb"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
fi

if [ "$UPLOAD" = 1 ] && [ "$TAP" = 1 ]; then
  echo "==> Cask: bath/homebrew-tap"
  TAP_SHA="$(gh api repos/bath/homebrew-tap/contents/Casks/hark.rb --jq .sha 2>/dev/null || true)"
  gh api -X PUT repos/bath/homebrew-tap/contents/Casks/hark.rb \
    -f message="hark $VERSION (cask)" -f content="$(base64 <"$CASK")" ${TAP_SHA:+-f sha="$TAP_SHA"} >/dev/null
  echo "Commit Casks/hark.rb here, then run: brew update && brew audit --strict --cask bath/tap/hark"
fi

echo "$DMG"
echo "sha256 $SHA"
