#!/usr/bin/env bash
# Git repo with one tracked modification, one untracked file, and one ignored file.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md notes *.txt *.ignored .gitignore 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "# Test Project" > CLAUDE.md
echo "*.ignored" > .gitignore
echo "v1" > tracked.txt
git add CLAUDE.md .gitignore tracked.txt
git commit -q -m "Initial commit"

echo "v2 modified" > tracked.txt
mkdir -p notes
echo "draft plan" > notes/draft.md
echo "ignored local output" > local.ignored
