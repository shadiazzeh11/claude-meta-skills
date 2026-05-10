#!/usr/bin/env bash
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md 2>/dev/null
echo "# Test" > CLAUDE.md
