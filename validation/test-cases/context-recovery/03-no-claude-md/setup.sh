#!/usr/bin/env bash
# Git project directory; no CLAUDE.md exists. Hook should create one at
# the project root instead of discovering the parent validation repo.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "v1 content" > foo.txt
git add foo.txt
git commit -q -m "Initial commit"
