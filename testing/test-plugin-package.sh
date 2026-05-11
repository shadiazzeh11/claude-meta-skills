#!/usr/bin/env bash
# Validate the Claude Code plugin scaffold. This is intentionally limited to
# package shape and command mapping; marketplace install behavior lives in
# testing/test-marketplace-package.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Test: plugin JSON parses"
jq -e . .claude-plugin/plugin.json >/dev/null
jq -e . hooks/hooks.json >/dev/null

echo "Test: plugin hook commands match template commands with plugin-root paths"
python3 - <<'PY'
import copy
import json
import sys
from pathlib import Path

root = Path.cwd()
manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
template = json.loads((root / "templates" / "settings.json").read_text())
plugin = json.loads((root / "hooks" / "hooks.json").read_text())

required_manifest = {
    "name": "claude-meta-skills",
    "license": "MIT",
}
for key, expected in required_manifest.items():
    actual = manifest.get(key)
    if actual != expected:
        raise SystemExit(f"manifest {key!r} expected {expected!r}, got {actual!r}")

if "hooks" in manifest:
    raise SystemExit(
        "manifest must not declare hooks; Claude Code auto-loads the standard hooks/hooks.json path"
    )

expected_hooks = copy.deepcopy(template["hooks"])

def rewrite_commands(node):
    if isinstance(node, dict):
        for key, value in list(node.items()):
            if key == "command" and isinstance(value, str):
                node[key] = value.replace(
                    "$CLAUDE_PROJECT_DIR/hooks/",
                    "${CLAUDE_PLUGIN_ROOT}/hooks/",
                )
            else:
                rewrite_commands(value)
    elif isinstance(node, list):
        for item in node:
            rewrite_commands(item)

rewrite_commands(expected_hooks)

if plugin.get("hooks") != expected_hooks:
    print("plugin hooks do not match template hooks after path rewrite", file=sys.stderr)
    print("expected:", json.dumps(expected_hooks, indent=2, sort_keys=True), file=sys.stderr)
    print("actual:", json.dumps(plugin.get("hooks"), indent=2, sort_keys=True), file=sys.stderr)
    raise SystemExit(1)

pretool_entries = plugin["hooks"].get("PreToolUse", [])
ordered_commands = []
for entry in pretool_entries:
    for hook in entry.get("hooks", []):
        if isinstance(hook, dict):
            ordered_commands.append(hook.get("command", ""))
gate_pos = next((i for i, command in enumerate(ordered_commands)
                 if "/construction-gate/hook.py" in command), None)
edit_pos = next((i for i, command in enumerate(ordered_commands)
                 if "/edit-drift-detector/hook.py" in command), None)
if gate_pos is None or edit_pos is None:
    raise SystemExit("plugin PreToolUse entries must include construction-gate and edit-drift-detector")
if gate_pos >= edit_pos:
    raise SystemExit("construction-gate must precede edit-drift-detector in plugin hooks")

commands = []

def collect_commands(node):
    if isinstance(node, dict):
        command = node.get("command")
        if isinstance(command, str):
            commands.append(command)
        for value in node.values():
            collect_commands(value)
    elif isinstance(node, list):
        for item in node:
            collect_commands(item)

collect_commands(plugin["hooks"])
if len(commands) != 5:
    raise SystemExit(f"expected 5 plugin hook commands, found {len(commands)}")
for command in commands:
    if "${CLAUDE_PLUGIN_ROOT}" not in command:
        raise SystemExit(f"plugin command does not use CLAUDE_PLUGIN_ROOT: {command}")
    if "$CLAUDE_PROJECT_DIR/hooks/" in command or ".claude/hooks/meta-skills" in command:
        raise SystemExit(f"plugin command still uses local-install path: {command}")

print("plugin hook mapping OK")
PY

echo "Test: claude plugin validate, when Claude Code is available"
if command -v claude >/dev/null 2>&1; then
  claude plugin validate .claude-plugin/plugin.json
else
  echo "SKIP: claude command not found; JSON and hook mapping checks passed"
fi

echo "All plugin package tests passed."
