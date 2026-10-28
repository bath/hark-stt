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
for required in ("hark_files", "server_agent", "accessibility", "microphone", "karabiner_rule", "ready"):
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
# hark.works serves docs/, so these copies must match the repo files.
for file in llms.txt install.sh AGENTS.md; do
  cmp -s "$ROOT/$file" "$ROOT/docs/$file" || { echo "FAIL: docs/$file (served at hark.works/$file) must match $file; run cp $file docs/" >&2; exit 1; }
done
echo "PASS: hark doctor reports a next step and uninstall needs --yes"
