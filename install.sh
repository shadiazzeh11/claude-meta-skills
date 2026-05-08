#!/usr/bin/env bash
# claude-meta-skills installer.
#
# Usage:
#   ./install.sh <target-project-path>             # install hooks
#   ./install.sh <target> --with-claude-md         # also copy CLAUDE.md template
#   ./install.sh <target> --verify                 # run validation harness after install
#   ./install.sh --help                            # show this message
#
# What it does:
#   1. Copies all 5 hooks to <target>/.claude/hooks/meta-skills/
#   2. Creates or merges <target>/.claude/settings.json (preserves any
#      existing hooks the user already has)
#   3. Optionally installs the CLAUDE.md template (--with-claude-md)
#   4. Optionally runs validation against the source repo (--verify)
#
# Settings.json merge requires jq. Without jq, the script prints the
# JSON snippet for the user to merge manually.

set -euo pipefail

TARGET=""
WITH_CLAUDE_MD=false
VERIFY=false

usage() {
  cat <<'EOF'
Usage: install.sh <target-project-path> [--with-claude-md] [--verify]

Options:
  --with-claude-md    Also install CLAUDE.md template at target root
                      (skipped if target already has CLAUDE.md)
  --verify            Run the source repo's validation harness after
                      installation completes (45 test cases)
  -h, --help          Show this message
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --with-claude-md)
      WITH_CLAUDE_MD=true
      ;;
    --verify)
      VERIFY=true
      ;;
    -*)
      echo "Unknown flag: $arg" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      else
        echo "Error: multiple target paths specified" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Error: target project path required" >&2
  usage >&2
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "Error: target directory does not exist: $TARGET" >&2
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_INSTALL_DIR="$TARGET/.claude/hooks/meta-skills"
SETTINGS_FILE="$TARGET/.claude/settings.json"
HOOKS=(
  edit-drift-detector
  completion-verifier
  silent-file-verifier
  construction-gate
  context-recovery
)

echo "claude-meta-skills installer"
echo "  Source: $REPO_DIR"
echo "  Target: $TARGET"
echo

# Step 1: copy hook directories
echo "[1/3] Copying hooks to .claude/hooks/meta-skills/"
mkdir -p "$HOOK_INSTALL_DIR"
for hook in "${HOOKS[@]}"; do
  src="$REPO_DIR/hooks/$hook"
  if [ ! -d "$src" ]; then
    echo "  WARN: $hook not found in source; skipping"
    continue
  fi
  rm -rf "$HOOK_INSTALL_DIR/$hook"
  cp -R "$src" "$HOOK_INSTALL_DIR/"
  # Strip Python bytecode caches that may have been copied from source
  find "$HOOK_INSTALL_DIR/$hook" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
  find "$HOOK_INSTALL_DIR/$hook" -name "*.pyc" -delete 2>/dev/null || true
  # Ensure hook.py is executable
  chmod +x "$HOOK_INSTALL_DIR/$hook/hook.py" 2>/dev/null || true
  echo "  installed: $hook"
done

# Step 2: settings.json (create or merge)
echo
echo "[2/3] Configuring .claude/settings.json"
mkdir -p "$TARGET/.claude"

# Build the install-target settings: rewrite paths from the templates' source
# layout ($CLAUDE_PROJECT_DIR/hooks/...) to the install layout
# ($CLAUDE_PROJECT_DIR/.claude/hooks/meta-skills/...).
NEW_SETTINGS="$(sed 's|\$CLAUDE_PROJECT_DIR/hooks/|$CLAUDE_PROJECT_DIR/.claude/hooks/meta-skills/|g' "$REPO_DIR/templates/settings.json")"

if [ -f "$SETTINGS_FILE" ]; then
  echo "  existing settings.json found; merging hooks..."
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "  WARN: jq not installed; cannot auto-merge."
    echo "  Manual step required: merge the .hooks entries from the JSON below"
    echo "  into your existing $SETTINGS_FILE:"
    echo
    echo "$NEW_SETTINGS"
    echo
  else
    BACKUP="$SETTINGS_FILE.backup-$(date +%s)"
    cp "$SETTINGS_FILE" "$BACKUP"
    echo "  backup: $BACKUP"

    # Deep-merge: keep user's existing settings, append our hooks within each
    # event (don't overwrite user's other hooks). Drops our internal _comment_*
    # keys since they're noise once installed.
    MERGED=$(jq -s '
      .[0] as $existing | .[1] as $ours |
      ($existing.hooks // {}) as $eh |
      ($ours.hooks // {}) as $oh |
      ($eh | keys + ($oh | keys) | unique) as $all_events |
      $existing * {hooks: (
        reduce $all_events[] as $ev ({};
          .[$ev] = (($eh[$ev] // []) + ($oh[$ev] // []))
        )
      )}
    ' "$SETTINGS_FILE" <(echo "$NEW_SETTINGS"))

    echo "$MERGED" > "$SETTINGS_FILE"
    echo "  merged hooks into existing settings.json"
  fi
else
  # Strip _comment_* keys for clean install output
  if command -v jq >/dev/null 2>&1; then
    echo "$NEW_SETTINGS" | jq 'del(.. | objects | ._comment_purpose, ._comment_versions)' > "$SETTINGS_FILE"
  else
    echo "$NEW_SETTINGS" > "$SETTINGS_FILE"
  fi
  echo "  created $SETTINGS_FILE"
fi

# Step 3: optional CLAUDE.md template
echo
if [ "$WITH_CLAUDE_MD" = true ]; then
  echo "[3/3] Installing CLAUDE.md template"
  if [ -f "$TARGET/CLAUDE.md" ]; then
    echo "  CLAUDE.md already exists at $TARGET/CLAUDE.md; skipping"
  else
    cp "$REPO_DIR/templates/CLAUDE.md" "$TARGET/CLAUDE.md"
    echo "  installed: CLAUDE.md template at $TARGET/CLAUDE.md"
  fi
else
  echo "[3/3] CLAUDE.md template skipped (use --with-claude-md to install)"
fi

echo
echo "Installation complete."
echo "  Hooks: $HOOK_INSTALL_DIR (5 hooks)"
echo "  Settings: $SETTINGS_FILE"

# Step 4: optional verification
if [ "$VERIFY" = true ]; then
  echo
  echo "Verifying with source repo's validation harness..."
  cd "$REPO_DIR"
  pass_total=0
  for h in "${HOOKS[@]}"; do
    output="$(./validation/harness.sh "$h" 2>&1 || true)"
    summary="$(echo "$output" | grep -E '^Total:' | head -1)"
    echo "  $h: $summary"
  done
  echo
  echo "Run './install.sh --help' for usage details."
fi
