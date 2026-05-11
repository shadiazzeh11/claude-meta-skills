#!/usr/bin/env bash
# Project root has CLAUDE.md and .git; hook invoked from a nested cwd
# should update root CLAUDE.md instead of creating src/nested/CLAUDE.md.
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
cat > CLAUDE.md <<'EOF'
# Root Project

Root CLAUDE content should be preserved.
EOF
