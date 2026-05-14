#!/usr/bin/env bash
# Git repo with 200 in-progress files. Recovery section should truncate
# the in-progress file list to stay under ~2000 chars.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md *.txt 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
for i in $(seq 1 200); do
  echo "v1" > "file_$i.txt"
done
git add . >/dev/null 2>&1
git commit -q -m "Initial 200 files"
for i in $(seq 1 200); do
  echo "v2" > "file_$i.txt"
done
echo "# Test" > CLAUDE.md
