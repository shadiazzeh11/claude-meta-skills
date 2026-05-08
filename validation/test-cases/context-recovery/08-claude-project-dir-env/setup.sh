#!/usr/bin/env bash
# CLAUDE_PROJECT_DIR env var points to a different directory than cwd.
# Hook should write to env-var directory, not cwd.
PROJ="$TEST_DIR/project"
OTHER="$TEST_DIR/other-dir"
mkdir -p "$PROJ" "$OTHER"
rm -f "$PROJ/CLAUDE.md" "$OTHER/CLAUDE.md"
echo "# Cwd-resident CLAUDE" > "$PROJ/CLAUDE.md"
echo "Should not be modified by hook." >> "$PROJ/CLAUDE.md"
