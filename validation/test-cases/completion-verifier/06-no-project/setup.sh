#!/usr/bin/env bash
# Empty git directory with no recognizable project config. The git boundary
# prevents parent discovery from leaking into the enclosing validation repo.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
