#!/usr/bin/env bash
# Hark installer. Installs Hark.app from the latest GitHub release.
#
#   curl -fsSL https://hark.works/install.sh | bash
#
# Old Hark versions (1.x, the Hammerspoon version) run this script for
# `hark update`. It installs Hark.app and removes the old version. It accepts
# their options: --json prints the app's doctor report on stdout and progress
# on stderr; other options are ignored.
set -euo pipefail

JSON=0
for arg in "$@"; do
  [ "$arg" = "--json" ] && JSON=1
done
if [ "$JSON" = 1 ]; then exec 3>&1 1>&2; else exec 3>&1; fi

say() { printf '==> %s\n' "$*"; }
die() { printf 'hark: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Hark needs macOS."
[ "$(uname -m)" = arm64 ] || die "Hark needs a Mac with Apple silicon."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Hark needs macOS 14 or later."

APP=/Applications/Hark.app
say "Finding the latest Hark.app"
url="$(curl -fsSL https://api.github.com/repos/bath/hark-stt/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*Hark-[0-9.]*\.dmg"' | cut -d'"' -f4 | head -1)"
[ -n "$url" ] || die "could not find Hark.app on https://github.com/bath/hark-stt/releases/latest"

work="$(mktemp -d)"
trap 'hdiutil detach -quiet "$work/mount" 2>/dev/null || true; rm -rf "$work"' EXIT
say "Downloading $url"
curl -fL --progress-bar "$url" -o "$work/Hark.dmg"
hdiutil attach -nobrowse -quiet -mountpoint "$work/mount" "$work/Hark.dmg"

osascript -e 'quit app id "works.hark.Hark"' >/dev/null 2>&1 || true
rm -rf "$APP"
ditto "$work/mount/Hark.app" "$APP"
say "Installed $APP"

# The Hammerspoon version: remove it, so two Harks do not share the keys.
if [ -x "$HOME/.hammerspoon/hark/bin/hark" ]; then
  say "Removing the old Hammerspoon version of Hark"
  "$HOME/.hammerspoon/hark/bin/hark" uninstall --yes || true
  rm -f "$HOME/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"
fi

open "$APP"
say "Hark is open. Allow the microphone, and turn on Hark in System Settings → Privacy & Security → Accessibility."

if [ "$JSON" = 1 ]; then
  "$APP/Contents/MacOS/Hark" doctor --json --wait 15 >&3 || true
fi
