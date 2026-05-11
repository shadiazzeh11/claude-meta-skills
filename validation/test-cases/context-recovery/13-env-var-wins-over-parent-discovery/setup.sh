#!/usr/bin/env bash
# cwd is nested under a discoverable project root, but CLAUDE_PROJECT_DIR
# points elsewhere and must remain authoritative.
PROJ="$TEST_DIR/project"
OTHER="$TEST_DIR/other-dir"
mkdir -p "$PROJ/src/nested" "$OTHER"
cd "$PROJ" || exit 1
rm -rf .git CLAUDE.md src/nested/CLAUDE.md foo.txt "$OTHER/CLAUDE.md" 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "v1 content" > foo.txt
git add foo.txt
git commit -q -m "Initial commit"
cat > CLAUDE.md <<'EOF'
# Cwd Project

This parent CLAUDE.md should not be modified when CLAUDE_PROJECT_DIR is set.
EOF
cat > "$OTHER/CLAUDE.md" <<'EOF'
# Env Target

Env target content should be preserved.
EOF
