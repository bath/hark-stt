#!/usr/bin/env bash
# The hark CLI gives agents a JSON report with a next step, and never removes
# anything without --yes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hark-cli-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

report="$(HOME="$TMP/home" APPLICATIONS_DIR="$TMP/apps" "$ROOT/bin/hark" doctor --json || true)"
/usr/bin/python3 - "$report" <<'PY'
import json, sys
report = json.loads(sys.argv[1])
assert report["ok"] is False, "an empty home must not pass"
ids = [c["id"] for c in report["checks"]]
for required in ("hark_files", "hark_current", "server_agent", "accessibility", "microphone", "karabiner_rule", "ready"):
    assert required in ids, "missing check " + required
step = report["next_step"]
assert step and not step["ok"] and step["required"] and step["fix"], "next_step must be a failed required check with a fix"
for c in report["checks"]:
    if not c["ok"]:
        assert c["fix"], "every failed check needs a fix: " + c["id"]
        assert isinstance(c["needs_human"], bool), "every failed check says if a human must act: " + c["id"]
PY

if HOME="$TMP/home" "$ROOT/bin/hark" uninstall >/dev/null; then
  echo "FAIL: uninstall without --yes must refuse" >&2
  exit 1
fi
HOME="$TMP/home" "$ROOT/bin/hark" open-settings nowhere 2>/dev/null && { echo "FAIL: unknown pane must fail" >&2; exit 1; }
[ "$("$ROOT/bin/hark" version)" = "$(grep -o 'VERSION        = "[^"]*"' "$ROOT/hark.lua" | cut -d'"' -f2)" ] || {
  echo "FAIL: bin/hark and hark.lua must report the same version" >&2
  exit 1
}
# `hark setup` runs the installer that Homebrew put next to bin/, and
# `hark update` upgrades the formula, then runs the new setup with the same hotkey choice.
mkdir -p "$TMP/pkg/bin" "$TMP/fakebin" "$TMP/home/.hammerspoon/hark"
cp "$ROOT/bin/hark" "$TMP/pkg/bin/hark"
cat >"$TMP/pkg/install.sh" <<'MOCK'
echo "installer $*" >>"$HARK_LOG"
MOCK
cat >"$TMP/fakebin/brew" <<MOCK
#!/bin/bash
echo "brew \$*" >>"\$HARK_LOG"
[ "\$1" = "--prefix" ] && echo "$TMP/pkg"
exit 0
MOCK
chmod +x "$TMP/fakebin/brew"
echo 'local VERSION        = "1.0.0"' >"$TMP/home/.hammerspoon/hark/init.lua"
export HARK_LOG="$TMP/log"
HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" "$TMP/pkg/bin/hark" setup --json
HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" "$TMP/pkg/bin/hark" update --json 2>/dev/null
expected="installer --json
brew list --formula hark
brew upgrade hark
brew --prefix hark
installer --json --no-karabiner"
[ "$(cat "$HARK_LOG")" = "$expected" ] || {
  printf 'FAIL: setup/update ran:\n%s\nexpected:\n%s\n' "$(cat "$HARK_LOG")" "$expected" >&2
  exit 1
}

# A curl install downloads the installer. A page that is not the installer,
# such as a domain parking page, is skipped for the next source.
# Never run "$ROOT/bin/hark" update or setup here: in a checkout, install.sh is
# next to bin/, so it would run the real installer against the live session.
mkdir -p "$TMP/web" "$TMP/nobrew" "$TMP/curl/bin"
cp "$ROOT/bin/hark" "$TMP/curl/bin/hark"
for command in launchctl killall open lsof; do printf '#!/bin/bash\nexit 0\n' >"$TMP/nobrew/$command"; done
echo '<!doctype html><title>Coming Soon</title>' >"$TMP/web/parking.html"
printf '#!/usr/bin/env bash\n# Hark installer. (test)\necho "downloaded installer $*" >>"$HARK_LOG"\n' >"$TMP/web/install.sh"
printf '#!/bin/bash\nexit 1\n' >"$TMP/nobrew/brew"
chmod +x "$TMP/nobrew/"*
: >"$HARK_LOG"
HOME="$TMP/home" PATH="$TMP/nobrew:$PATH" HARK_INSTALLER_URLS="file://$TMP/web/parking.html file://$TMP/web/install.sh" \
  "$TMP/curl/bin/hark" update --json 2>/dev/null
[ "$(cat "$HARK_LOG")" = "downloaded installer --json --no-karabiner" ] || {
  printf 'FAIL: a curl update ran:\n%s\n' "$(cat "$HARK_LOG")" >&2
  exit 1
}
if HOME="$TMP/home" PATH="$TMP/nobrew:$PATH" HARK_INSTALLER_URLS="file://$TMP/web/parking.html" \
  "$TMP/curl/bin/hark" update 2>/dev/null; then
  echo "FAIL: update must fail when no source serves the installer" >&2
  exit 1
fi

# hark.works serves docs/, so these copies must match the repo files.
for file in llms.txt install.sh AGENTS.md; do
  cmp -s "$ROOT/$file" "$ROOT/docs/$file" || { echo "FAIL: docs/$file (served at hark.works/$file) must match $file; run cp $file docs/" >&2; exit 1; }
done
echo "PASS: hark doctor reports a next step, update and setup run the right installer, uninstall needs --yes"
