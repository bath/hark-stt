#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hark-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
mkdir -p "$TMP/applications"

cat >"$TMP/bin/uname" <<'MOCK'
#!/usr/bin/env bash
echo Darwin
MOCK

cat >"$TMP/bin/brew" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BREW_LOG"
# Homebrew subprocesses may read inherited stdin. Deliberately do so here to
# reproduce the failure mode of a curl-streamed installer.
if IFS= read -r line; then
  printf 'consumed: %s\n' "$line" >>"$BREW_STDIN_LOG"
  cat >/dev/null
fi
MOCK

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      dest="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */hark.lua)
    cp "$REPO_ROOT/hark.lua" "$dest"
    ;;
  */recorder/HarkRecorder.swift)
    cp "$REPO_ROOT/recorder/HarkRecorder.swift" "$dest"
    ;;
  */bin/hark)
    cp "$REPO_ROOT/bin/hark" "$dest"
    ;;
  */sounds/generate.py)
    cp "$REPO_ROOT/sounds/generate.py" "$dest"
    ;;
  */karabiner/hark.json)
    cp "$REPO_ROOT/karabiner/hark.json" "$dest"
    ;;
  */ggml-large-v3-turbo-q5_0.bin)
    : >"$dest"
    ;;
  *)
    echo "Unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
MOCK

# launchctl and lsof must never reach the real user session: the installer
# replaces the LaunchAgent and kills whatever holds the server port.
for command in open killall sleep launchctl lsof; do
  cat >"$TMP/bin/$command" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
done
chmod +x "$TMP/bin/"*

# An old whisper-dictation install that the installer must move to Hark.
mkdir -p "$TMP/home/.hammerspoon/bin" "$TMP/home/.hammerspoon/whisper-sounds" "$TMP/home/Library/LaunchAgents"
printf 'require("hs.ipc")\nrequire("whisper-dictation")\n' >"$TMP/home/.hammerspoon/init.lua"
: >"$TMP/home/.hammerspoon/whisper-dictation.lua"
: >"$TMP/home/.hammerspoon/bin/whisper-recorder"
: >"$TMP/home/Library/LaunchAgents/com.whisper-dictation.server.plist"

: >"$TMP/brew.log"
: >"$TMP/brew-stdin.log"

# Feed the script slowly so Bash cannot buffer the whole installer before a
# child process gets a chance to steal the pipe. This makes the regression
# deterministic instead of dependent on pipe-buffer timing.
stream_installer() {
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    /bin/sleep 0.003
  done <"$ROOT/install.sh"
}

output="$({ stream_installer; } | env \
  PATH="$TMP/bin:/usr/bin:/bin" \
  HOME="$TMP/home" \
  APPLICATIONS_DIR="$TMP/applications" \
  BREW_LOG="$TMP/brew.log" \
  BREW_STDIN_LOG="$TMP/brew-stdin.log" \
  REPO_ROOT="$ROOT" \
  HARK_STATUS_WAIT=0 \
  bash 2>&1)"

if [ -s "$TMP/brew-stdin.log" ]; then
  echo "FAIL: a Homebrew command consumed the streamed installer:" >&2
  cat "$TMP/brew-stdin.log" >&2
  exit 1
fi

for invocation in \
  "install whisper-cpp" \
  "install --cask hammerspoon" \
  "install --cask karabiner-elements"; do
  if ! grep -Fxq "$invocation" "$TMP/brew.log"; then
    echo "FAIL: missing Homebrew invocation: $invocation" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

for artifact in \
  "$TMP/home/.cache/whisper/ggml-large-v3-turbo-q5_0.bin" \
  "$TMP/home/.hammerspoon/hark/init.lua" \
  "$TMP/home/.hammerspoon/hark/HarkRecorder.swift" \
  "$TMP/home/.hammerspoon/hark/bin/hark-recorder" \
  "$TMP/home/.hammerspoon/hark/bin/hark" \
  "$TMP/home/.hammerspoon/hark/sounds/packs.json" \
  "$TMP/home/.hammerspoon/hark/sounds/pop/start.wav" \
  "$TMP/home/Library/LaunchAgents/com.hark-stt.server.plist" \
  "$TMP/home/.config/karabiner/assets/complex_modifications/hark.json"; do
  if [ ! -f "$artifact" ]; then
    echo "FAIL: installer did not create $artifact" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

grep -Fq 'Files installed. macOS needs these clicks before Hark can work:' <<<"$output"
grep -Fq 'If F5 asks you to turn on Apple' <<<"$output"
grep -Fq 'Hark is ready to dictate' <<<"$output"
grep -Eq '^local MIC[[:space:]]*= nil' "$TMP/home/.hammerspoon/hark/init.lua"
test -x "$TMP/home/.hammerspoon/hark/bin/hark-recorder"
test -x "$TMP/home/.hammerspoon/hark/bin/hark"

# The old install is gone and init.lua loads Hark exactly once.
for old in \
  "$TMP/home/.hammerspoon/whisper-dictation.lua" \
  "$TMP/home/.hammerspoon/bin/whisper-recorder" \
  "$TMP/home/.hammerspoon/whisper-sounds" \
  "$TMP/home/Library/LaunchAgents/com.whisper-dictation.server.plist"; do
  if [ -e "$old" ]; then
    echo "FAIL: installer left the old install file $old" >&2
    exit 1
  fi
done
if grep -q 'whisper-dictation' "$TMP/home/.hammerspoon/init.lua" || [ "$(grep -c 'require("hark")' "$TMP/home/.hammerspoon/init.lua")" != 1 ]; then
  echo "FAIL: init.lua should load Hark once and no longer load whisper-dictation" >&2
  cat "$TMP/home/.hammerspoon/init.lua" >&2
  exit 1
fi
if grep -Fq 'local MIC     = ":0"' "$TMP/home/.hammerspoon/hark/init.lua"; then
  echo "FAIL: installed config still assumes AVFoundation device 0 is the built-in mic" >&2
  exit 1
fi
echo "PASS: streamed installer survives child processes reading stdin"
