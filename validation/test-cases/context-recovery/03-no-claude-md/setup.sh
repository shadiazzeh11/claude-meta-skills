#!/usr/bin/env bash
# Empty project directory; no CLAUDE.md exists. Hook should create one.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md 2>/dev/null
