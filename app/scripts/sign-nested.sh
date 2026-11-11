#!/usr/bin/env bash
# Signs the code inside Hark.app, innermost first, so that the app's own
# signature can come last. Sparkle has helpers inside its framework, and each
# one needs its own signature (sparkle-project.org/documentation/sandboxing/#code-signing).
#
#   app/scripts/sign-nested.sh APP IDENTITY [codesign options…]
set -euo pipefail

APP="$1"
IDENTITY="$2"
shift 2
FRAMEWORKS="$APP/Contents/Frameworks"
SPARKLE="$FRAMEWORKS/Sparkle.framework/Versions/B"

sign() { codesign --force --sign "$IDENTITY" "$@"; }

sign "$@" "$SPARKLE/XPCServices/Installer.xpc"
# The downloader's entitlements are Sparkle's, not Hark's.
sign "$@" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$@" "$SPARKLE/Autoupdate"
sign "$@" "$SPARKLE/Updater.app"
sign "$@" "$FRAMEWORKS/Sparkle.framework"
sign "$@" "$FRAMEWORKS/whisper.framework"
