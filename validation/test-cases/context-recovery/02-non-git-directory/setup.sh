#!/usr/bin/env bash
# Non-git directory with a CLAUDE.md.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md 2>/dev/null
echo "# Non-git Project" > CLAUDE.md
echo "Some baseline content." >> CLAUDE.md
