#!/usr/bin/env bash
# Validate the Claude Code marketplace catalog and, when the local Claude CLI is
# available, exercise add/list/install/uninstall in isolated temp config dirs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MARKETPLACE=".claude-plugin/marketplace.json"
PLUGIN=".claude-plugin/plugin.json"
MARKETPLACE_NAME="claude-meta-skills-marketplace"
PLUGIN_NAME="claude-meta-skills"

echo "Test: marketplace JSON parses"
jq -e . "$MARKETPLACE" >/dev/null
jq -e . "$PLUGIN" >/dev/null

echo "Test: marketplace manifest matches plugin metadata"
python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
marketplace = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
plugin = json.loads((root / ".claude-plugin" / "plugin.json").read_text())

reserved_names = {
    "claude-code-marketplace",
    "claude-code-plugins",
    "claude-plugins-official",
    "anthropic-marketplace",
    "anthropic-plugins",
    "agent-skills",
    "knowledge-work-plugins",
    "life-sciences",
}

expected_marketplace = "claude-meta-skills-marketplace"
if marketplace.get("name") != expected_marketplace:
    raise SystemExit(f"marketplace name expected {expected_marketplace!r}, got {marketplace.get('name')!r}")
if marketplace["name"] in reserved_names:
    raise SystemExit(f"marketplace name is reserved: {marketplace['name']}")

owner = marketplace.get("owner")
if not isinstance(owner, dict) or owner.get("name") != plugin["author"]["name"]:
    raise SystemExit("marketplace owner.name must match plugin author.name")

plugins = marketplace.get("plugins")
if not isinstance(plugins, list) or len(plugins) != 1:
    raise SystemExit("marketplace must contain exactly one plugin entry")

entry = plugins[0]
expected_pairs = {
    "name": plugin["name"],
    "source": "./",
    "description": plugin["description"],
    "homepage": plugin["homepage"],
    "repository": plugin["repository"],
    "license": plugin["license"],
}
for key, expected in expected_pairs.items():
    actual = entry.get(key)
    if actual != expected:
        raise SystemExit(f"marketplace plugin {key!r} expected {expected!r}, got {actual!r}")

if entry.get("author", {}).get("name") != plugin["author"]["name"]:
    raise SystemExit("marketplace plugin author.name must match plugin author.name")
if entry.get("keywords") != plugin["keywords"]:
    raise SystemExit("marketplace plugin keywords must match plugin keywords")
if entry.get("source") != "./":
    raise SystemExit("relative plugin source must be './' so it resolves to the marketplace root")
if "version" in entry:
    raise SystemExit("marketplace plugin entry must not duplicate plugin.json version")

print("marketplace manifest metadata OK")
PY

echo "Test: claude marketplace validate/install path, when Claude Code is available"
if command -v claude >/dev/null 2>&1; then
  TEST_ROOT="$(mktemp -d /tmp/claude-meta-marketplace-test.XXXXXX)"
  cleanup() {
    rm -rf "$TEST_ROOT"
  }
  trap cleanup EXIT

  mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/config" "$TEST_ROOT/plugins" "$TEST_ROOT/tmp"

  run_claude() {
    HOME="$TEST_ROOT/home" \
    CLAUDE_CONFIG_DIR="$TEST_ROOT/config" \
    CLAUDE_CODE_PLUGIN_CACHE_DIR="$TEST_ROOT/plugins" \
    CLAUDE_CODE_TMPDIR="$TEST_ROOT/tmp" \
    claude "$@"
  }

  run_claude plugin validate "$MARKETPLACE"
  run_claude plugin marketplace add "$ROOT" --scope user
  run_claude plugin marketplace list --json > "$TEST_ROOT/marketplaces.json"
  python3 - "$TEST_ROOT/marketplaces.json" "$MARKETPLACE_NAME" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
needle = sys.argv[2]
if needle not in json.dumps(data, sort_keys=True):
    raise SystemExit(f"marketplace {needle!r} not found in marketplace list JSON")
print("marketplace list includes expected catalog")
PY

  run_claude plugin list --json --available > "$TEST_ROOT/available.json"
  python3 - "$TEST_ROOT/available.json" "$PLUGIN_NAME" "$MARKETPLACE_NAME" <<'PY'
import json
import sys
from pathlib import Path

rendered = json.dumps(json.loads(Path(sys.argv[1]).read_text()), sort_keys=True)
for needle in sys.argv[2:]:
    if needle not in rendered:
        raise SystemExit(f"expected {needle!r} in available plugin JSON")
print("available plugin list includes expected plugin")
PY

  run_claude plugin install "$PLUGIN_NAME@$MARKETPLACE_NAME" --scope user
  run_claude plugin list --json > "$TEST_ROOT/installed.json"
  python3 - "$TEST_ROOT/installed.json" "$PLUGIN_NAME" "$MARKETPLACE_NAME" <<'PY'
import json
import sys
from pathlib import Path

rendered = json.dumps(json.loads(Path(sys.argv[1]).read_text()), sort_keys=True)
for needle in sys.argv[2:]:
    if needle not in rendered:
        raise SystemExit(f"expected {needle!r} in installed plugin JSON")
print("installed plugin list includes expected plugin")
PY

  run_claude plugin uninstall "$PLUGIN_NAME@$MARKETPLACE_NAME" --scope user --keep-data --yes
  run_claude plugin marketplace remove "$MARKETPLACE_NAME"
else
  echo "SKIP: claude command not found; JSON and manifest checks passed"
fi

echo "All marketplace package tests passed."
