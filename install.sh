#!/usr/bin/env bash
# claude-meta-skills installer.
#
# Usage:
#   ./install.sh <target-project-path>             # install hooks
#   ./install.sh <target> --with-claude-md         # also copy CLAUDE.md template
#   ./install.sh <target> --verify                 # run validation harness after install
#   ./install.sh <target> --uninstall              # remove installed hooks/settings entries
#   ./install.sh --help                            # show this message
#
# What it does:
#   1. Copies all 5 hooks to <target>/.claude/hooks/meta-skills/
#   2. Creates or merges <target>/.claude/settings.json (preserves any
#      existing hooks the user already has). Idempotent: re-running the
#      installer replaces prior meta-skills hook entries instead of
#      appending duplicates.
#   3. Optionally installs the CLAUDE.md template (--with-claude-md)
#   4. Optionally runs validation against the source repo (--verify)
#
# Uninstall removes only meta-skills hook entries from settings.json and
# deletes <target>/.claude/hooks/meta-skills/. It preserves unrelated hooks,
# unrelated settings, and CLAUDE.md.
#
# Settings.json merge/uninstall requires jq. Without jq, install prints the
# JSON snippet for the user to merge manually; uninstall stops before changing
# files and prints the exact manual cleanup scope.

set -euo pipefail

TARGET=""
WITH_CLAUDE_MD=false
VERIFY=false
UNINSTALL=false

usage() {
  cat <<'EOF'
Usage: install.sh <target-project-path> [--with-claude-md] [--verify] [--uninstall]

Options:
  --with-claude-md    Also install CLAUDE.md template at target root
                      (skipped if target already has CLAUDE.md)
  --verify            Run the source repo's full validation suite after
                      installation completes
  --uninstall         Remove meta-skills hook entries from .claude/settings.json
                      and delete .claude/hooks/meta-skills/
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
    --uninstall)
      UNINSTALL=true
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

if [ "$UNINSTALL" = true ] && [ "$WITH_CLAUDE_MD" = true ]; then
  echo "Error: --uninstall cannot be combined with --with-claude-md" >&2
  usage >&2
  exit 1
fi

if [ "$UNINSTALL" = true ] && [ "$VERIFY" = true ]; then
  echo "Error: --uninstall cannot be combined with --verify" >&2
  usage >&2
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

backup_settings() {
  local base backup n
  base="$SETTINGS_FILE.backup-$(date +%s)"
  backup="$base"
  n=1
  while [ -e "$backup" ]; do
    backup="$base-$n"
    n=$((n + 1))
  done
  cp "$SETTINGS_FILE" "$backup"
  echo "$backup"
}

uninstall_meta_skills() {
  echo "claude-meta-skills uninstaller"
  echo "  Target: $TARGET"
  echo

  if [ -f "$SETTINGS_FILE" ]; then
    echo "[1/2] Removing meta-skills entries from .claude/settings.json"
    if ! command -v jq >/dev/null 2>&1; then
      echo
      echo "  ERROR: jq not installed; cannot safely edit existing settings.json." >&2
      echo "  No files were changed." >&2
      echo "  Manual cleanup scope:" >&2
      echo "    - Remove hook commands whose command contains '.claude/hooks/meta-skills/'" >&2
      echo "    - Then delete $HOOK_INSTALL_DIR" >&2
      exit 1
    fi

    META_COUNT=$(jq '
      [
        .hooks // {}
        | to_entries[]?
        | .value[]?
        | (.hooks // [])[]?
        | select((.command // "") | contains(".claude/hooks/meta-skills/"))
      ] | length
    ' "$SETTINGS_FILE")

    if [ "$META_COUNT" = "0" ]; then
      echo "  no meta-skills hook entries found; settings unchanged"
    else
      CLEANED=$(jq '
      def is_meta_skills_command:
        (.command // "") | contains(".claude/hooks/meta-skills/");

      def strip_meta_skills_entry:
        .hooks = ((.hooks // []) | map(select(is_meta_skills_command | not)));

      def filter_existing_event:
        map(strip_meta_skills_entry)
        | map(select((.hooks // []) | length > 0));

      . as $existing |
      ($existing.hooks // {}) as $eh |
      $existing
      | .hooks = (
        reduce ($eh | keys[]) as $ev ({};
          (($eh[$ev] // []) | filter_existing_event) as $filtered |
          if ($filtered | length) > 0 then .[$ev] = $filtered else . end
        )
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
      ' "$SETTINGS_FILE")

      BACKUP="$(backup_settings)"
      echo "  backup: $BACKUP"
      echo "$CLEANED" > "$SETTINGS_FILE"
      echo "  removed meta-skills hook entries; unrelated settings/hooks preserved"
    fi
  else
    echo "[1/2] No .claude/settings.json found; skipping settings cleanup"
  fi

  echo
  echo "[2/2] Removing copied hook files"
  if [ -d "$HOOK_INSTALL_DIR" ]; then
    rm -rf "$HOOK_INSTALL_DIR"
    echo "  removed: $HOOK_INSTALL_DIR"
  else
    echo "  no copied hook directory found at $HOOK_INSTALL_DIR"
  fi

  echo
  echo "Uninstall complete."
  echo "  Settings: $SETTINGS_FILE"
  echo "  Hooks removed: $HOOK_INSTALL_DIR"
  echo "  CLAUDE.md was not removed."
}

if [ "$UNINSTALL" = true ]; then
  uninstall_meta_skills
  exit 0
fi

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
    BACKUP="$(backup_settings)"
    echo "  backup: $BACKUP"

    # Idempotent merge: strip any prior meta-skills hook commands from each
    # event (signature: command path contains ".claude/hooks/meta-skills/"),
    # preserving the user's unrelated hooks (including any commands that
    # share an entry with a meta-skills command), then append the fresh
    # meta-skills entries from the current template. Re-running install on
    # the same target produces the same result as a single install.
    MERGED=$(jq -s '
      def is_meta_skills_command:
        (.command // "") | contains(".claude/hooks/meta-skills/");

      def strip_meta_skills_entry:
        .hooks = ((.hooks // []) | map(select(is_meta_skills_command | not)));

      def filter_existing_event:
        map(strip_meta_skills_entry)
        | map(select((.hooks // []) | length > 0));

      .[0] as $existing | .[1] as $ours |
      ($existing.hooks // {}) as $eh |
      ($ours.hooks // {}) as $oh |
      ($eh | keys + ($oh | keys) | unique) as $all_events |
      $existing
      | .hooks = (
        reduce $all_events[] as $ev ({};
          .[$ev] = (($eh[$ev] // [] | filter_existing_event) + ($oh[$ev] // []))
        )
      )
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
  verify_fail=0
  verify_failed_hooks=""
  for h in "${HOOKS[@]}"; do
    # Capture exit without aborting under set -e. Harness exits nonzero
    # if any test case in the suite failed (failed-test count == its exit).
    output="$(./validation/harness.sh "$h" 2>&1)" && hook_status=0 || hook_status=$?
    summary="$(echo "$output" | grep -E '^Total:' | head -1)"
    if [ "$hook_status" -ne 0 ]; then
      echo "  $h: $summary (FAIL exit=$hook_status)"
      verify_fail=1
      verify_failed_hooks="$verify_failed_hooks $h"
    else
      echo "  $h: $summary"
    fi
  done
  echo
  if [ "$verify_fail" -ne 0 ]; then
    echo "Validation FAILED for hooks:$verify_failed_hooks" >&2
    exit 1
  fi
  echo "Run './install.sh --help' for usage details."
fi
