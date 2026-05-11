#!/usr/bin/env bash
# Read-only diagnostics for claude-meta-skills.
#
# Usage:
#   ./doctor.sh                 # check this source checkout
#   ./doctor.sh /path/to/project # also check a local install target
#
# The doctor never installs, uninstalls, edits settings, truncates logs, or
# invokes hooks. It reports FAIL only for broken required files/configuration;
# missing optional tools or missing target installs are WARN.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-${TARGET:-}}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

HOOKS=(
  edit-drift-detector
  construction-gate
  silent-file-verifier
  completion-verifier
  context-recovery
)

usage() {
  cat <<'EOF'
Usage: doctor.sh [target-project-path]

Checks this claude-meta-skills checkout and, when a target path is provided,
checks the local install wiring under <target>/.claude/.

Environment:
  TARGET=<path>    Alternative way to provide the target project path.
EOF
}

ok() {
  OK_COUNT=$((OK_COUNT + 1))
  printf 'OK   %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$*"
}

json_valid() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys
from pathlib import Path

try:
    json.loads(Path(sys.argv[1]).read_text())
except Exception as exc:
    print(exc)
    raise SystemExit(1)
PY
}

check_file() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    ok "$label exists: ${file#$ROOT/}"
  else
    fail "$label missing: ${file#$ROOT/}"
  fi
}

check_executable_file() {
  local file="$1"
  local label="$2"
  if [ ! -f "$file" ]; then
    fail "$label missing: ${file#$ROOT/}"
  elif [ ! -x "$file" ]; then
    fail "$label is not executable: ${file#$ROOT/}"
  else
    ok "$label exists and is executable: ${file#$ROOT/}"
  fi
}

check_json_file() {
  local file="$1"
  local label="$2"
  if [ ! -f "$file" ]; then
    fail "$label missing: ${file#$ROOT/}"
    return
  fi
  if json_valid "$file" >/dev/null; then
    ok "$label JSON parses: ${file#$ROOT/}"
  else
    fail "$label JSON does not parse: ${file#$ROOT/}"
  fi
}

command_version() {
  local command_name="$1"
  "$command_name" --version 2>/dev/null | head -1
}

check_commands() {
  if command -v python3 >/dev/null 2>&1; then
    ok "python3 found: $(command_version python3)"
  else
    fail "python3 not found; hooks require python3"
  fi

  if command -v jq >/dev/null 2>&1; then
    ok "jq found: $(command_version jq)"
  else
    warn "jq not found; installer cannot auto-merge existing settings.json"
  fi

  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI found: $(command_version claude)"
  else
    warn "claude CLI not found; plugin/marketplace smoke checks cannot run here"
  fi
}

check_source_tree() {
  echo "Source checkout: $ROOT"
  echo
  check_commands
  echo

  check_executable_file "$ROOT/install.sh" "installer"
  check_json_file "$ROOT/templates/settings.json" "settings template"
  check_json_file "$ROOT/hooks/hooks.json" "plugin hooks"
  check_json_file "$ROOT/.claude-plugin/plugin.json" "plugin manifest"
  check_json_file "$ROOT/.claude-plugin/marketplace.json" "marketplace catalog"

  for hook in "${HOOKS[@]}"; do
    if [ -d "$ROOT/hooks/$hook" ]; then
      ok "hook directory exists: hooks/$hook"
    else
      fail "hook directory missing: hooks/$hook"
      continue
    fi
    check_executable_file "$ROOT/hooks/$hook/hook.py" "$hook hook.py"
    check_file "$ROOT/hooks/$hook/README.md" "$hook README"
    check_file "$ROOT/hooks/$hook/BASELINE-RESULTS.md" "$hook baseline"
    check_json_file "$ROOT/hooks/$hook/messages.json" "$hook messages"
    if [ -f "$ROOT/hooks/$hook/rules.json" ]; then
      check_json_file "$ROOT/hooks/$hook/rules.json" "$hook rules"
    fi
  done

  python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
template = json.loads((root / "templates" / "settings.json").read_text())
plugin_hooks = json.loads((root / "hooks" / "hooks.json").read_text())

expected_template = {
    "construction-gate": ("PreToolUse", "Write|Edit|MultiEdit|NotebookEdit"),
    "edit-drift-detector": ("PreToolUse", "Edit"),
    "silent-file-verifier": ("PostToolUse", "Write|Edit|MultiEdit|NotebookEdit"),
    "completion-verifier": ("Stop", None),
    "context-recovery": ("PreCompact", None),
}

def command_entries(settings):
    for event, entries in settings.get("hooks", {}).items():
        for entry in entries:
            matcher = entry.get("matcher")
            for hook in entry.get("hooks", []):
                command = hook.get("command", "")
                yield event, matcher, command

entries = list(command_entries(template))
errors = []
for hook, (event, matcher) in expected_template.items():
    matches = [
        (ev, ma, cmd) for ev, ma, cmd in entries
        if f"/{hook}/hook.py" in cmd
    ]
    if len(matches) != 1:
        errors.append(f"{hook}: expected exactly one template command, found {len(matches)}")
        continue
    ev, ma, cmd = matches[0]
    if ev != event:
        errors.append(f"{hook}: expected event {event}, got {ev}")
    if matcher is not None and ma != matcher:
        errors.append(f"{hook}: expected matcher {matcher}, got {ma}")
    if "$CLAUDE_PROJECT_DIR/hooks/" not in cmd:
        errors.append(f"{hook}: template command should use $CLAUDE_PROJECT_DIR/hooks/")

plugin_entries = list(command_entries(plugin_hooks))
if len(plugin_entries) != 5:
    errors.append(f"plugin hooks: expected 5 commands, found {len(plugin_entries)}")
for _, _, command in plugin_entries:
    if "${CLAUDE_PLUGIN_ROOT}/hooks/" not in command:
        errors.append(f"plugin command should use CLAUDE_PLUGIN_ROOT: {command}")

if errors:
    for error in errors:
        print(error)
    raise SystemExit(1)
PY
  if [ "$?" -eq 0 ]; then
    ok "settings template and plugin hooks contain the expected five hook commands"
  else
    fail "settings template/plugin hook command mapping is inconsistent"
  fi
}

check_log() {
  local log_file="${HOME:-}/.claude/meta-skills-log.jsonl"
  echo
  if [ -z "${HOME:-}" ]; then
    warn "HOME is not set; cannot locate meta-skills log"
    return
  fi

  if [ -f "$log_file" ]; then
    local lines
    lines="$(wc -l < "$log_file" | tr -d ' ')"
    ok "meta-skills log exists: $log_file ($lines lines; contents not printed)"
  else
    warn "meta-skills log not found at $log_file (normal before first hook fire)"
  fi
}

check_target_install() {
  local target="$1"
  echo
  echo "Install target: $target"

  if [ ! -d "$target" ]; then
    fail "target directory does not exist: $target"
    return
  fi

  target="$(cd "$target" && pwd)"
  local settings="$target/.claude/settings.json"
  local local_settings="$target/.claude/settings.local.json"
  local hook_root="$target/.claude/hooks/meta-skills"

  if [ ! -f "$settings" ]; then
    warn "target has no .claude/settings.json; local install not detected"
  elif json_valid "$settings" >/dev/null; then
    ok "target settings JSON parses: $settings"
  else
    fail "target settings JSON does not parse: $settings"
  fi

  if [ -f "$local_settings" ]; then
    if json_valid "$local_settings" >/dev/null; then
      ok "target settings.local.json parses: $local_settings"
    else
      fail "target settings.local.json does not parse: $local_settings"
    fi
  fi

  for settings_candidate in "$settings" "$local_settings"; do
    if [ -f "$settings_candidate" ] && json_valid "$settings_candidate" >/dev/null; then
      if python3 - "$settings_candidate" <<'PY' >/dev/null
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
raise SystemExit(0 if data.get("disableAllHooks") is True else 1)
PY
      then
        warn "$(basename "$settings_candidate") sets disableAllHooks=true; Claude Code will skip hooks"
      fi
    fi
  done

  if [ -d "$hook_root" ]; then
    ok "target hook directory exists: $hook_root"
  else
    warn "target hook directory missing: $hook_root"
  fi

  for hook in "${HOOKS[@]}"; do
    if [ -f "$hook_root/$hook/hook.py" ]; then
      if [ -x "$hook_root/$hook/hook.py" ]; then
        ok "target $hook hook.py exists and is executable"
      else
        fail "target $hook hook.py exists but is not executable"
      fi
    elif [ -d "$hook_root" ]; then
      fail "target $hook hook.py missing"
    else
      warn "target $hook hook.py missing"
    fi
  done

  if [ -f "$settings" ] && json_valid "$settings" >/dev/null; then
    python3 - "$settings" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "construction-gate": ("PreToolUse", "Write|Edit|MultiEdit|NotebookEdit"),
    "edit-drift-detector": ("PreToolUse", "Edit"),
    "silent-file-verifier": ("PostToolUse", "Write|Edit|MultiEdit|NotebookEdit"),
    "completion-verifier": ("Stop", None),
    "context-recovery": ("PreCompact", None),
}

entries = []
for event, event_entries in settings.get("hooks", {}).items():
    for entry in event_entries:
        matcher = entry.get("matcher")
        for hook in entry.get("hooks", []):
            command = hook.get("command", "")
            entries.append((event, matcher, command))

errors = []
warnings = []
for hook, (event, matcher) in expected.items():
    matches = [
        (ev, ma, cmd) for ev, ma, cmd in entries
        if f".claude/hooks/meta-skills/{hook}/hook.py" in cmd
    ]
    if len(matches) != 1:
        errors.append(f"{hook}: expected exactly one installed command, found {len(matches)}")
        continue
    ev, ma, command = matches[0]
    if ev != event:
        errors.append(f"{hook}: expected event {event}, got {ev}")
    if matcher is not None and ma != matcher:
        errors.append(f"{hook}: expected matcher {matcher}, got {ma}")
    if "$CLAUDE_PROJECT_DIR/hooks/" in command:
        errors.append(f"{hook}: command still uses source template path")
    if "${CLAUDE_PLUGIN_ROOT}" in command:
        warnings.append(f"{hook}: command uses plugin-root path; doctor target checks are for local install")

for warning in warnings:
    print(f"WARN\t{warning}")
for error in errors:
    print(f"FAIL\t{error}")
if errors:
    raise SystemExit(1)
PY
    local status=$?
    if [ "$status" -eq 0 ]; then
      ok "target settings contain expected local meta-skills hook entries"
    else
      fail "target settings local hook entries are incomplete or inconsistent"
    fi
  fi

  if [ -f "$target/CLAUDE.md" ]; then
    ok "target CLAUDE.md exists"
  else
    warn "target CLAUDE.md not found (optional; install with --with-claude-md if wanted)"
  fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

echo "claude-meta-skills doctor"
echo "========================="
echo

check_source_tree
check_log

if [ -n "$TARGET" ]; then
  check_target_install "$TARGET"
else
  echo
  warn "no target project provided; skipping local install checks"
  echo "     Run: ./doctor.sh /path/to/project"
fi

echo
echo "Summary: $OK_COUNT OK, $WARN_COUNT WARN, $FAIL_COUNT FAIL"

if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
