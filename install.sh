#!/usr/bin/env bash
# Hark installer. Private, on-device dictation for macOS.
# Run it either way:
#   curl -fsSL https://raw.githubusercontent.com/bath/hark-stt/main/install.sh | bash
#   ./install.sh            (from a local clone)
#
# Options (pass after `bash -s --` when piping from curl):
#   --no-karabiner   skip Karabiner-Elements; dictate with ⌥Space instead of F5
#   --json           print only the final `hark doctor --json` report on stdout
#                    (progress goes to stderr), for AI agents and scripts
#
# It installs everything that CAN be automated: Homebrew packages, the Whisper
# model, the native recorder, the sound library, the configs and the server
# LaunchAgent. It CANNOT grant macOS permissions (Microphone, Accessibility,
# Karabiner's driver and rule). `hark doctor` lists what is left and how to fix it.
# An existing whisper-dictation install is moved to the Hark names.
set -euo pipefail

RAW="https://raw.githubusercontent.com/bath/hark-stt/main"
MODEL_DIR="$HOME/.cache/whisper"
MODEL="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
HS_DIR="$HOME/.hammerspoon"
HARK_DIR="$HS_DIR/hark"
RECORDER_SRC="$HARK_DIR/HarkRecorder.swift"
RECORDER="$HARK_DIR/bin/hark-recorder"
KB_DIR="$HOME/.config/karabiner/assets/complex_modifications"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-/Applications}"
SERVER_LABEL="com.hark-stt.server"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/$SERVER_LABEL.plist"
SERVER_PORT=8178
SERVER_LOG="/tmp/hark-server.log"
OLD_SERVER_LABEL="com.whisper-dictation.server"

WITH_KARABINER=1
JSON=0
for arg in "$@"; do
  case "$arg" in
    --no-karabiner) WITH_KARABINER=0 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# In --json mode stdout carries only the doctor report.
if [ "$JSON" = 1 ]; then exec 3>&1 1>&2; else exec 3>&1; fi

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
# When this installer is streamed via `curl | bash`, its source code is stdin.
# Never let Homebrew or one of its subprocesses consume the rest of the script.
brew_install() { brew install "$@" </dev/null; }

# Use local files if run from a clone; otherwise download them.
SELF="${BASH_SOURCE[0]:-}"
SRC_DIR=""
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/hark.lua" ]; then
  SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi
fetch() { # <repo-relative-path> <dest>
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "$2"
  else curl -fsSL "$RAW/$1" -o "$2"; fi
}

[ "$(uname)" = "Darwin" ] || { echo "Hark is macOS-only."; exit 1; }

say "Homebrew"
if ! have brew; then
  echo "Homebrew is required. Install it from https://brew.sh then re-run:"
  echo '  curl -fsSL '"$RAW"'/install.sh | bash'
  exit 1
fi
echo "  ok"

say "Command-line tools (whisper-server, Swift compiler)"
have whisper-server || { echo "  installing whisper-cpp"; brew_install whisper-cpp; }
have xcrun && xcrun --find swiftc >/dev/null 2>&1 || {
  echo "Apple Command Line Tools are required. Run: xcode-select --install"
  exit 1
}
echo "  ok"

say "Apps (Hammerspoon$([ "$WITH_KARABINER" = 1 ] && echo ", Karabiner-Elements"))"
[ -d "$APPLICATIONS_DIR/Hammerspoon.app" ] || { echo "  installing hammerspoon"; brew_install --cask hammerspoon; }
if [ "$WITH_KARABINER" = 1 ] && [ ! -d "$APPLICATIONS_DIR/Karabiner-Elements.app" ]; then
  # This cask installs a system driver, so Homebrew may ask for the password.
  echo "  installing karabiner-elements"
  brew_install --cask karabiner-elements
fi
echo "  ok"

say "Whisper model (~550 MB)"
if [ -f "$MODEL" ]; then echo "  already present"; else
  mkdir -p "$MODEL_DIR"
  curl -fL --progress-bar "$MODEL_URL" -o "$MODEL"
fi

say "Moving an old whisper-dictation install to Hark"
if [ -f "$HS_DIR/whisper-dictation.lua" ] || [ -f "$AGENT_DIR/$OLD_SERVER_LABEL.plist" ]; then
  launchctl bootout "gui/$(id -u)/$OLD_SERVER_LABEL" >/dev/null 2>&1 || true
  rm -f "$AGENT_DIR/$OLD_SERVER_LABEL.plist" \
        "$HS_DIR/whisper-dictation.lua" "$HS_DIR/WhisperRecorder.swift" \
        "$HS_DIR/bin/whisper-recorder" "$HS_DIR/whisper-sounds-generate.py" \
        "$KB_DIR/whisper-dictation.json"
  rm -rf "$HS_DIR/whisper-sounds"
  rmdir "$HS_DIR/bin" 2>/dev/null || true
  if [ -f "$HS_DIR/init.lua" ]; then
    /usr/bin/sed -i '' 's/require("whisper-dictation")/require("hark")/' "$HS_DIR/init.lua"
  fi
  echo "  moved (your sound and island settings carry over)"
else
  echo "  nothing to move"
fi

say "Hark files"
mkdir -p "$HARK_DIR/bin"
fetch "hark.lua" "$HARK_DIR/init.lua"
fetch "recorder/HarkRecorder.swift" "$RECORDER_SRC"
xcrun swiftc -O \
  -framework AudioToolbox \
  -framework AudioUnit \
  -framework CoreAudio \
  "$RECORDER_SRC" -o "$RECORDER" </dev/null
fetch "sounds/generate.py" "$HARK_DIR/generate-sounds.py"
/usr/bin/python3 "$HARK_DIR/generate-sounds.py" "$HARK_DIR/sounds" </dev/null
fetch "bin/hark" "$HARK_DIR/bin/hark"
chmod +x "$HARK_DIR/bin/hark"
touch "$HS_DIR/init.lua"
if ! grep -q 'require("hark")' "$HS_DIR/init.lua"; then
  printf '\nrequire("hark")\n' >> "$HS_DIR/init.lua"
fi
echo "  installed → $HARK_DIR (recorder, sounds, hark CLI)"

install_server_agent() {
say "Whisper server LaunchAgent (launchd keeps it alive)"
SERVER_BIN="$(command -v whisper-server || echo /opt/homebrew/bin/whisper-server)"
mkdir -p "$AGENT_DIR"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SERVER_BIN</string>
    <string>-m</string><string>$MODEL</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$SERVER_PORT</string>
    <string>-l</string><string>en</string>
    <string>-nt</string>
    <string>-nlp</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$SERVER_LOG</string>
  <key>StandardErrorPath</key><string>$SERVER_LOG</string>
</dict>
</plist>
PLIST
# Replace any previous agent, then free the port from orphaned servers left
# behind by older Hammerspoon-launched setups.
launchctl bootout "gui/$(id -u)/$SERVER_LABEL" >/dev/null 2>&1 || true
ORPHANS="$(lsof -ti "tcp:$SERVER_PORT" 2>/dev/null || true)"
if [ -n "$ORPHANS" ]; then
  echo "  stopping orphaned process(es) on port $SERVER_PORT"
  kill $ORPHANS 2>/dev/null || true
  sleep 1
fi
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
echo "  installed + started → $AGENT_PLIST (log: $SERVER_LOG)"
}

if [ "$WITH_KARABINER" = 1 ]; then
  say "Karabiner rule (F5 / dictation key → F18)"
  mkdir -p "$KB_DIR"
  fetch "karabiner/hark.json" "$KB_DIR/hark.json"
  echo "  rule file installed → $KB_DIR"
  echo "  IMPORTANT: Karabiner does not turn on imported rules by itself."
fi

say "Restarting Hammerspoon"
# Restart BEFORE installing the LaunchAgent: an old running config relaunches
# its own whisper-server when its child dies, and would race the new agent.
killall Hammerspoon >/dev/null 2>&1 || true
sleep 1; open -a Hammerspoon

install_server_agent
[ "$WITH_KARABINER" = 1 ] && { open -a Karabiner-Elements >/dev/null 2>&1 || true; }

say "Checking the setup"
# Give Hammerspoon a moment to load Hark and write its first status report.
"$HARK_DIR/bin/hark" doctor --wait "${HARK_STATUS_WAIT:-20}" $([ "$JSON" = 1 ] && echo --json) >&3 || true

[ "$JSON" = 1 ] && exit 0
echo
bold "✅ Files installed. macOS needs these clicks before Hark can work:"
cat <<'STEPS'

  1. Hammerspoon permissions. System Settings → Privacy & Security:
       • Microphone    → turn on Hammerspoon
       • Accessibility → turn on Hammerspoon
STEPS
if [ "$WITH_KARABINER" = 1 ]; then
cat <<'STEPS'

  2. Karabiner-Elements (just opened):
       • Approve its driver / system extension and Input Monitoring when asked
       • Settings → Complex Modifications → Add rule → turn on "F5 / Dictation key → F18"
       • If F5 asks you to turn on Apple's Dictation, this rule is still off

  3. (optional) System Settings → Keyboard → Dictation → Off
       so Apple's dictation does not also start on that key.
STEPS
fi
cat <<'STEPS'

Then click into any text field, press F5 (or ⌥Space), talk, and press it again.
Run ~/.hammerspoon/hark/bin/hark doctor any time to see what is left.
STEPS
