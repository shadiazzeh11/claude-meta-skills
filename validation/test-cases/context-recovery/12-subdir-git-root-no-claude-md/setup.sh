#!/usr/bin/env bash
# Git root has no CLAUDE.md. Hook invoked from nested cwd should create
# CLAUDE.md at the git root, not inside the nested directory.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ/src/nested"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md src/nested/CLAUDE.md foo.txt 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "v1 content" > foo.txt
git add foo.txt
git commit -q -m "Initial commit"
echo "v2 content modified" > foo.txt
