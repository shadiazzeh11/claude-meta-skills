#!/usr/bin/env bash
# Set up a git repo with a commit, modified files, and CLAUDE.md.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md *.txt 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "v1 content" > foo.txt
echo "v1 content" > bar.txt
git add foo.txt bar.txt
git commit -q -m "Initial commit"
git commit -q --allow-empty -m "Second commit"
echo "v2 content modified" > foo.txt
cat > CLAUDE.md <<'EOF'
# Test Project

This is the original CLAUDE.md content. It should be preserved
when the recovery section is appended.

## Project conventions
- Run tests before committing
EOF
