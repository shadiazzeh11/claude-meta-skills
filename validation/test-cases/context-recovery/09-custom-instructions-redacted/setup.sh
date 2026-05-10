#!/usr/bin/env bash
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "# Test" > CLAUDE.md
echo "v1" > app.txt
git add . >/dev/null 2>&1
git commit -q -m "Initial"
echo "v2" > app.txt
