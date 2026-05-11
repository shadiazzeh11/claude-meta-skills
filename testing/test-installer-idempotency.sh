#!/usr/bin/env bash
# Installer tests for claude-meta-skills.
#
# Runs install.sh against temporary /tmp targets and asserts that
# repeated installs produce identical settings.json (no duplicated
# meta-skills hook entries) while preserving any unrelated hooks the
# user has configured. Also verifies that uninstall removes only
# meta-skills hook entries and copied hook files. Does not invoke hooks,
# does not write under $HOME, and does not use --verify, so the dogfood
# log at ~/.claude/meta-skills-log.jsonl is not touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
META_SIG=".claude/hooks/meta-skills/"

if [ ! -x "$INSTALL" ] && [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh not found at $INSTALL" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for installer lifecycle tests" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /tmp/claude-meta-idem.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mktemp_target() {
  local name="$1"
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  echo "$dir"
}

run_install() {
  "$INSTALL" "$1" >/dev/null
}

run_uninstall() {
  "$INSTALL" "$1" --uninstall >/dev/null
}

signatures() {
  jq -r '
    .hooks // {}
    | to_entries[]
    | .key as $event
    | .value[]
    | .matcher as $matcher
    | (.hooks // [])[]
    | [$event, ($matcher // ""), .type, .command]
    | @tsv
  ' "$1"
}

meta_signature_count() {
  local count
  count="$(signatures "$1" | grep -c -F "$META_SIG" || true)"
  echo "$count"
}

unique_meta_signature_count() {
  signatures "$1" | { grep -F "$META_SIG" || true; } | sort -u | wc -l | tr -d ' '
}

command_count() {
  local count
  count="$(signatures "$1" | grep -c -F -- "$2" || true)"
  echo "$count"
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: $3" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $1" >&2
    exit 1
  fi
}

assert_settings_equal() {
  if ! diff -q "$1" "$2" >/dev/null; then
    echo "FAIL: $3" >&2
    diff -u "$1" "$2" >&2 || true
    exit 1
  fi
}

assert_path_exists() {
  if [ ! -e "$1" ]; then
    echo "FAIL: $2" >&2
    echo "  expected path to exist: $1" >&2
    exit 1
  fi
}

assert_path_absent() {
  if [ -e "$1" ]; then
    echo "FAIL: $2" >&2
    echo "  expected path to be absent: $1" >&2
    exit 1
  fi
}

# Permanent assertion: the installed construction-gate hook entry must use
# matcher "Write|Edit|MultiEdit|NotebookEdit" so it covers every file-modifying
# tool, not just Write. Regression guard for Phase 2B.3.
assert_construction_gate_matcher() {
  local settings_file="$1"
  local label="$2"
  local matcher
  matcher="$(jq -r '
    [
      .hooks.PreToolUse // []
      | .[]
      | select(
          (.hooks // [])
          | any(.command // "" | contains("/construction-gate/hook.py"))
        )
      | .matcher
    ] | unique | join(",")
  ' "$settings_file")"
  if [ "$matcher" != "Write|Edit|MultiEdit|NotebookEdit" ]; then
    echo "FAIL: $label: construction-gate matcher must be 'Write|Edit|MultiEdit|NotebookEdit'" >&2
    echo "  actual: $matcher" >&2
    exit 1
  fi
}

# Permanent assertion: construction-gate must precede edit-drift-detector for
# PreToolUse so protected Edit payloads are blocked before any hook can read
# nearby file content for fuzzy correction feedback.
assert_pretooluse_privacy_order() {
  local settings_file="$1"
  local label="$2"
  python3 - "$settings_file" "$label" <<'PY'
import json
import sys

settings_path, label = sys.argv[1], sys.argv[2]
data = json.load(open(settings_path))
entries = data.get("hooks", {}).get("PreToolUse", [])
ordered_commands = []
for entry in entries:
    for hook in entry.get("hooks", []):
        if not isinstance(hook, dict):
            continue
        ordered_commands.append(hook.get("command", ""))

gate_pos = next((i for i, command in enumerate(ordered_commands)
                 if "/construction-gate/hook.py" in command), None)
edit_pos = next((i for i, command in enumerate(ordered_commands)
                 if "/edit-drift-detector/hook.py" in command), None)

if gate_pos is None or edit_pos is None:
    raise SystemExit(f"FAIL: {label}: missing construction-gate or edit-drift PreToolUse entry")
if gate_pos >= edit_pos:
    raise SystemExit(
        f"FAIL: {label}: construction-gate must precede edit-drift-detector "
        f"(gate position {gate_pos}, edit position {edit_pos})"
    )
PY
}

# -----------------------------------------------------------------------------
echo "Test A — empty target, two installs"
T_A="$(mktemp_target A)"

run_install "$T_A"
jq -e . "$T_A/.claude/settings.json" >/dev/null
A_FIRST="$T_A/settings.first.json"
jq -S . "$T_A/.claude/settings.json" > "$A_FIRST"

run_install "$T_A"
jq -e . "$T_A/.claude/settings.json" >/dev/null
A_SECOND="$T_A/settings.second.json"
jq -S . "$T_A/.claude/settings.json" > "$A_SECOND"

assert_settings_equal "$A_FIRST" "$A_SECOND" "Test A: settings differ between two installs"
assert_eq "$(meta_signature_count "$T_A/.claude/settings.json")" "5" "Test A: meta-skills signature count must be 5"
assert_eq "$(unique_meta_signature_count "$T_A/.claude/settings.json")" "5" "Test A: meta-skills unique signatures must be 5"
assert_construction_gate_matcher "$T_A/.claude/settings.json" "Test A"
assert_pretooluse_privacy_order "$T_A/.claude/settings.json" "Test A"
echo "PASS Test A"

# -----------------------------------------------------------------------------
echo "Test B — existing unrelated hook is preserved across installs"
T_B="$(mktemp_target B)"
mkdir -p "$T_B/.claude"
cat > "$T_B/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Read"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo existing-bash-hook"
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_B/.claude/settings.json" >/dev/null

run_install "$T_B"
B_FIRST="$T_B/settings.first.json"
jq -S . "$T_B/.claude/settings.json" > "$B_FIRST"

run_install "$T_B"
B_SECOND="$T_B/settings.second.json"
jq -S . "$T_B/.claude/settings.json" > "$B_SECOND"

assert_eq "$(command_count "$T_B/.claude/settings.json" "echo existing-bash-hook")" "1" "Test B: existing bash hook must appear exactly once"
PRESERVED="$(jq -r '.permissions.allow[0] // "MISSING"' "$T_B/.claude/settings.json")"
assert_eq "$PRESERVED" "Read" "Test B: unrelated top-level permissions key must be preserved"
assert_eq "$(meta_signature_count "$T_B/.claude/settings.json")" "5" "Test B: meta-skills signature count must be 5"
assert_eq "$(unique_meta_signature_count "$T_B/.claude/settings.json")" "5" "Test B: meta-skills unique signatures must be 5"
assert_settings_equal "$B_FIRST" "$B_SECOND" "Test B: settings differ between two installs"
assert_construction_gate_matcher "$T_B/.claude/settings.json" "Test B"
assert_pretooluse_privacy_order "$T_B/.claude/settings.json" "Test B"
echo "PASS Test B"

# -----------------------------------------------------------------------------
echo "Test C — pre-existing duplicate meta-skills entries are normalized"
T_C="$(mktemp_target C)"
run_install "$T_C"

# Artificially triple every event's entries to simulate older installer output
DUPED="$T_C/.claude/settings.json.duped"
jq '
  .hooks = (
    .hooks
    | to_entries
    | map(.value = (.value + .value + .value))
    | from_entries
  )
' "$T_C/.claude/settings.json" > "$DUPED"
mv "$DUPED" "$T_C/.claude/settings.json"
jq -e . "$T_C/.claude/settings.json" >/dev/null

PRE_REPAIR_COUNT="$(meta_signature_count "$T_C/.claude/settings.json")"
if [ "$PRE_REPAIR_COUNT" -le 5 ]; then
  echo "FAIL: Test C: pre-repair count must be > 5, got $PRE_REPAIR_COUNT" >&2
  exit 1
fi

run_install "$T_C"
jq -e . "$T_C/.claude/settings.json" >/dev/null

assert_eq "$(meta_signature_count "$T_C/.claude/settings.json")" "5" "Test C: post-repair signature count must be 5"
assert_eq "$(unique_meta_signature_count "$T_C/.claude/settings.json")" "5" "Test C: post-repair unique signatures must be 5"
assert_construction_gate_matcher "$T_C/.claude/settings.json" "Test C"
assert_pretooluse_privacy_order "$T_C/.claude/settings.json" "Test C"
echo "PASS Test C"

# -----------------------------------------------------------------------------
echo "Test D — mixed-command entry preserves the unrelated command"
T_D="$(mktemp_target D)"
mkdir -p "$T_D/.claude"
cat > "$T_D/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/meta-skills/edit-drift-detector/hook.py\""
          },
          {
            "type": "command",
            "command": "echo keep-me"
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_D/.claude/settings.json" >/dev/null

run_install "$T_D"
jq -e . "$T_D/.claude/settings.json" >/dev/null

assert_eq "$(command_count "$T_D/.claude/settings.json" "echo keep-me")" "1" "Test D: unrelated 'echo keep-me' command must appear exactly once"
assert_eq "$(meta_signature_count "$T_D/.claude/settings.json")" "5" "Test D: fresh meta-skills signature count must be 5"
assert_eq "$(unique_meta_signature_count "$T_D/.claude/settings.json")" "5" "Test D: meta-skills unique signatures must be 5"
assert_construction_gate_matcher "$T_D/.claude/settings.json" "Test D"
assert_pretooluse_privacy_order "$T_D/.claude/settings.json" "Test D"
echo "PASS Test D"

# -----------------------------------------------------------------------------
echo "Test E — uninstall removes meta-skills entries and copied hooks"
T_E="$(mktemp_target E)"

run_install "$T_E"
assert_path_exists "$T_E/.claude/hooks/meta-skills" "Test E: hook install dir must exist after install"
assert_eq "$(meta_signature_count "$T_E/.claude/settings.json")" "5" "Test E: meta-skills signature count must be 5 after install"
echo "# project guidance" > "$T_E/CLAUDE.md"

run_uninstall "$T_E"
jq -e . "$T_E/.claude/settings.json" >/dev/null
assert_eq "$(meta_signature_count "$T_E/.claude/settings.json")" "0" "Test E: meta-skills signatures must be removed after uninstall"
assert_eq "$(unique_meta_signature_count "$T_E/.claude/settings.json")" "0" "Test E: unique meta-skills signatures must be 0 after uninstall"
assert_path_absent "$T_E/.claude/hooks/meta-skills" "Test E: hook install dir must be removed after uninstall"
assert_path_exists "$T_E/CLAUDE.md" "Test E: CLAUDE.md must be preserved after uninstall"

# Re-running uninstall should be a clean no-op.
E_SETTINGS_BEFORE_NOOP="$T_E/settings.before-noop.json"
cp "$T_E/.claude/settings.json" "$E_SETTINGS_BEFORE_NOOP"
E_BACKUPS_BEFORE_NOOP="$(find "$T_E/.claude" -maxdepth 1 -name 'settings.json.backup-*' | wc -l | tr -d ' ')"
run_uninstall "$T_E"
jq -e . "$T_E/.claude/settings.json" >/dev/null
assert_eq "$(meta_signature_count "$T_E/.claude/settings.json")" "0" "Test E: repeated uninstall must keep meta-skills signatures at 0"
assert_path_absent "$T_E/.claude/hooks/meta-skills" "Test E: repeated uninstall must keep hook install dir absent"
assert_settings_equal "$E_SETTINGS_BEFORE_NOOP" "$T_E/.claude/settings.json" "Test E: repeated uninstall must not rewrite settings content"
E_BACKUPS_AFTER_NOOP="$(find "$T_E/.claude" -maxdepth 1 -name 'settings.json.backup-*' | wc -l | tr -d ' ')"
assert_eq "$E_BACKUPS_AFTER_NOOP" "$E_BACKUPS_BEFORE_NOOP" "Test E: repeated uninstall must not create another backup"
echo "PASS Test E"

# -----------------------------------------------------------------------------
echo "Test F — uninstall preserves unrelated hooks and top-level settings"
T_F="$(mktemp_target F)"
mkdir -p "$T_F/.claude"
cat > "$T_F/.claude/settings.json" <<'JSON'
{
  "disableAllHooks": false,
  "permissions": {
    "allow": ["Read"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo existing-bash-hook"
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_F/.claude/settings.json" >/dev/null

run_install "$T_F"
run_uninstall "$T_F"
jq -e . "$T_F/.claude/settings.json" >/dev/null

assert_eq "$(command_count "$T_F/.claude/settings.json" "echo existing-bash-hook")" "1" "Test F: existing bash hook must appear exactly once after uninstall"
F_PRESERVED="$(jq -r '.permissions.allow[0] // "MISSING"' "$T_F/.claude/settings.json")"
assert_eq "$F_PRESERVED" "Read" "Test F: unrelated top-level permissions key must be preserved after uninstall"
F_DISABLE="$(jq -r '.disableAllHooks' "$T_F/.claude/settings.json")"
assert_eq "$F_DISABLE" "false" "Test F: unrelated disableAllHooks key must be preserved after uninstall"
assert_eq "$(meta_signature_count "$T_F/.claude/settings.json")" "0" "Test F: meta-skills signatures must be removed"
assert_path_absent "$T_F/.claude/hooks/meta-skills" "Test F: hook install dir must be removed"
echo "PASS Test F"

# -----------------------------------------------------------------------------
echo "Test G — uninstall preserves unrelated command from mixed hook entry"
T_G="$(mktemp_target G)"
mkdir -p "$T_G/.claude/hooks/meta-skills/edit-drift-detector"
cat > "$T_G/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/meta-skills/edit-drift-detector/hook.py\""
          },
          {
            "type": "command",
            "command": "echo keep-me"
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_G/.claude/settings.json" >/dev/null

run_uninstall "$T_G"
jq -e . "$T_G/.claude/settings.json" >/dev/null

assert_eq "$(command_count "$T_G/.claude/settings.json" "echo keep-me")" "1" "Test G: unrelated 'echo keep-me' command must remain after uninstall"
assert_eq "$(meta_signature_count "$T_G/.claude/settings.json")" "0" "Test G: meta-skills signatures must be removed"
assert_path_absent "$T_G/.claude/hooks/meta-skills" "Test G: hook install dir must be removed"
echo "PASS Test G"

# -----------------------------------------------------------------------------
echo "Test H — uninstall removes relative meta-skills commands"
T_H="$(mktemp_target H)"
mkdir -p "$T_H/.claude/hooks/meta-skills/construction-gate"
cat > "$T_H/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/meta-skills/construction-gate/hook.py"
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_H/.claude/settings.json" >/dev/null

run_uninstall "$T_H"
jq -e . "$T_H/.claude/settings.json" >/dev/null

assert_eq "$(meta_signature_count "$T_H/.claude/settings.json")" "0" "Test H: relative meta-skills command must be removed"
assert_path_absent "$T_H/.claude/hooks/meta-skills" "Test H: hook install dir must be removed"
echo "PASS Test H"

# -----------------------------------------------------------------------------
echo "Test I — invalid settings aborts before deleting copied hooks"
T_I="$(mktemp_target I)"
mkdir -p "$T_I/.claude/hooks/meta-skills/construction-gate"
printf '{ invalid json\n' > "$T_I/.claude/settings.json"

if "$INSTALL" "$T_I" --uninstall >/dev/null 2>&1; then
  echo "FAIL: Test I: uninstall should fail when settings.json is invalid" >&2
  exit 1
fi

assert_path_exists "$T_I/.claude/hooks/meta-skills" "Test I: copied hook dir must remain when settings cleanup fails"
echo "PASS Test I"

# -----------------------------------------------------------------------------
echo "Test J — uninstall without jq fails before deleting copied hooks"
T_J="$(mktemp_target J)"
mkdir -p "$T_J/.claude/hooks/meta-skills/construction-gate"
cat > "$T_J/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/meta-skills/construction-gate/hook.py\""
          }
        ]
      }
    ]
  }
}
JSON
jq -e . "$T_J/.claude/settings.json" >/dev/null

NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
ln -s "$(command -v dirname)" "$NO_JQ_BIN/dirname"
BASH_BIN="$(command -v bash)"

if PATH="$NO_JQ_BIN" "$BASH_BIN" "$INSTALL" "$T_J" --uninstall >/dev/null 2>&1; then
  echo "FAIL: Test J: uninstall should fail when jq is unavailable and settings.json exists" >&2
  exit 1
fi

jq -e . "$T_J/.claude/settings.json" >/dev/null
assert_eq "$(meta_signature_count "$T_J/.claude/settings.json")" "1" "Test J: meta-skills signature must remain when jq is unavailable"
assert_path_exists "$T_J/.claude/hooks/meta-skills" "Test J: copied hook dir must remain when jq is unavailable"
echo "PASS Test J"

# -----------------------------------------------------------------------------
echo "Test K — make install/uninstall handles target paths with spaces"
T_K="$(mktemp_target "K parent")/project with spaces"
mkdir -p "$T_K"

make -C "$REPO_DIR" install TARGET="$T_K" >/dev/null
jq -e . "$T_K/.claude/settings.json" >/dev/null
assert_eq "$(meta_signature_count "$T_K/.claude/settings.json")" "5" "Test K: make install must install meta-skills entries with space-containing target path"
assert_path_exists "$T_K/.claude/hooks/meta-skills" "Test K: make install must copy hook dir with space-containing target path"

make -C "$REPO_DIR" uninstall TARGET="$T_K" >/dev/null
jq -e . "$T_K/.claude/settings.json" >/dev/null
assert_eq "$(meta_signature_count "$T_K/.claude/settings.json")" "0" "Test K: make uninstall must remove meta-skills entries with space-containing target path"
assert_path_absent "$T_K/.claude/hooks/meta-skills" "Test K: make uninstall must remove hook dir with space-containing target path"
echo "PASS Test K"

echo
echo "All installer tests passed."
