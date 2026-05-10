#!/usr/bin/env bash
# Installer idempotency tests for claude-meta-skills.
#
# Runs install.sh against temporary /tmp targets and asserts that
# repeated installs produce identical settings.json (no duplicated
# meta-skills hook entries) while preserving any unrelated hooks the
# user has configured. Does not invoke hooks, does not write under
# $HOME, and does not use --verify, so the dogfood log at
# ~/.claude/meta-skills-log.jsonl is not touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
META_SIG="/.claude/hooks/meta-skills/"

if [ ! -x "$INSTALL" ] && [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh not found at $INSTALL" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for installer idempotency tests" >&2
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
  signatures "$1" | grep -F "$META_SIG" | sort -u | wc -l | tr -d ' '
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
echo "PASS Test D"

echo
echo "All installer idempotency tests passed."
