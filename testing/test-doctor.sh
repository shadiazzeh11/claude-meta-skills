#!/usr/bin/env bash
# Regression tests for the read-only doctor diagnostics.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$ROOT/doctor.sh"
INSTALL="$ROOT/install.sh"

TMP_ROOT="$(mktemp -d /tmp/claude-meta-doctor.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.claude"
printf '%s\n' '{"hook":"probe","action":"ok"}' > "$HOME/.claude/meta-skills-log.jsonl"

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F "$needle" "$file" >/dev/null; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    cat "$file" >&2
    echo "--------------" >&2
    exit 1
  fi
}

echo "Test A — source-only doctor succeeds with warnings allowed"
SOURCE_OUT="$TMP_ROOT/source.out"
"$DOCTOR" > "$SOURCE_OUT"
assert_contains "$SOURCE_OUT" "claude-meta-skills doctor"
assert_contains "$SOURCE_OUT" "settings template and plugin hooks contain the expected five hook commands"
assert_contains "$SOURCE_OUT" "Summary:"
assert_contains "$SOURCE_OUT" "0 FAIL"
echo "PASS Test A"

echo "Test B — doctor still works when jq is absent from PATH"
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for cmd in python3 dirname head wc tr basename; do
  ln -s "$(command -v "$cmd")" "$NO_JQ_BIN/$cmd"
done
NO_JQ_OUT="$TMP_ROOT/no-jq.out"
PATH="$NO_JQ_BIN" /bin/bash "$DOCTOR" > "$NO_JQ_OUT"
assert_contains "$NO_JQ_OUT" "jq not found"
assert_contains "$NO_JQ_OUT" "0 FAIL"
echo "PASS Test B"

echo "Test C — clean target without install warns but does not fail"
CLEAN_TARGET="$TMP_ROOT/clean-target"
mkdir -p "$CLEAN_TARGET"
CLEAN_OUT="$TMP_ROOT/clean-target.out"
"$DOCTOR" "$CLEAN_TARGET" > "$CLEAN_OUT"
assert_contains "$CLEAN_OUT" "local install not detected"
assert_contains "$CLEAN_OUT" "0 FAIL"
echo "PASS Test C"

echo "Test D — installed target doctor succeeds"
TARGET="$TMP_ROOT/project"
mkdir -p "$TARGET"
"$INSTALL" "$TARGET" >/dev/null
TARGET_OUT="$TMP_ROOT/target.out"
"$DOCTOR" "$TARGET" > "$TARGET_OUT"
assert_contains "$TARGET_OUT" "target settings contain expected local meta-skills hook entries"
assert_contains "$TARGET_OUT" "target construction-gate hook.py exists and is executable"
assert_contains "$TARGET_OUT" "0 FAIL"
echo "PASS Test D"

echo "Test E — invalid target settings fails"
BROKEN="$TMP_ROOT/broken"
mkdir -p "$BROKEN/.claude"
printf '{not json\n' > "$BROKEN/.claude/settings.json"
BROKEN_OUT="$TMP_ROOT/broken.out"
if "$DOCTOR" "$BROKEN" > "$BROKEN_OUT" 2>&1; then
  echo "FAIL: doctor should fail on invalid target settings" >&2
  cat "$BROKEN_OUT" >&2
  exit 1
fi
assert_contains "$BROKEN_OUT" "target settings JSON does not parse"
assert_contains "$BROKEN_OUT" "FAIL"
echo "PASS Test E"

echo "Test F — duplicate installed hook commands fail"
DUPED="$TMP_ROOT/duped"
mkdir -p "$DUPED"
"$INSTALL" "$DUPED" >/dev/null
python3 - "$DUPED/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
pretool = data["hooks"]["PreToolUse"]
pretool.append(pretool[0])
path.write_text(json.dumps(data, indent=2) + "\n")
PY
DUPED_OUT="$TMP_ROOT/duped.out"
if "$DOCTOR" "$DUPED" > "$DUPED_OUT" 2>&1; then
  echo "FAIL: doctor should fail on duplicate installed hook commands" >&2
  cat "$DUPED_OUT" >&2
  exit 1
fi
assert_contains "$DUPED_OUT" "expected exactly one installed command"
assert_contains "$DUPED_OUT" "FAIL"
echo "PASS Test F"

echo "Test G — disableAllHooks warns without failing"
DISABLED="$TMP_ROOT/disabled"
mkdir -p "$DISABLED"
"$INSTALL" "$DISABLED" >/dev/null
python3 - "$DISABLED/.claude/settings.local.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(json.dumps({"disableAllHooks": True}, indent=2) + "\n")
PY
DISABLED_OUT="$TMP_ROOT/disabled.out"
"$DOCTOR" "$DISABLED" > "$DISABLED_OUT"
assert_contains "$DISABLED_OUT" "disableAllHooks=true"
assert_contains "$DISABLED_OUT" "0 FAIL"
echo "PASS Test G"

echo "Test H — installed copy drift warns without failing"
DRIFT="$TMP_ROOT/drift"
mkdir -p "$DRIFT"
"$INSTALL" "$DRIFT" >/dev/null
printf '\n# local drift probe\n' >> "$DRIFT/.claude/hooks/meta-skills/completion-verifier/hook.py"
DRIFT_OUT="$TMP_ROOT/drift.out"
"$DOCTOR" "$DRIFT" > "$DRIFT_OUT"
assert_contains "$DRIFT_OUT" "target completion-verifier hook.py differs from this checkout"
assert_contains "$DRIFT_OUT" "0 FAIL"
echo "PASS Test H"

echo "Test I — missing copied hook file fails"
MISSING_HOOK="$TMP_ROOT/missing-hook"
mkdir -p "$MISSING_HOOK"
"$INSTALL" "$MISSING_HOOK" >/dev/null
rm "$MISSING_HOOK/.claude/hooks/meta-skills/construction-gate/hook.py"
MISSING_HOOK_OUT="$TMP_ROOT/missing-hook.out"
if "$DOCTOR" "$MISSING_HOOK" > "$MISSING_HOOK_OUT" 2>&1; then
  echo "FAIL: doctor should fail when installed settings point at a missing hook file" >&2
  cat "$MISSING_HOOK_OUT" >&2
  exit 1
fi
assert_contains "$MISSING_HOOK_OUT" "target construction-gate hook.py missing"
assert_contains "$MISSING_HOOK_OUT" "FAIL"
echo "PASS Test I"

echo "Test J — missing target fails"
MISSING_OUT="$TMP_ROOT/missing.out"
if "$DOCTOR" "$TMP_ROOT/does-not-exist" > "$MISSING_OUT" 2>&1; then
  echo "FAIL: doctor should fail on missing target directory" >&2
  cat "$MISSING_OUT" >&2
  exit 1
fi
assert_contains "$MISSING_OUT" "target directory does not exist"
assert_contains "$MISSING_OUT" "FAIL"
echo "PASS Test J"

echo "All doctor tests passed."
