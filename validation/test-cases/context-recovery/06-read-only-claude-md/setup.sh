#!/usr/bin/env bash
# Read-only CLAUDE.md; hook must exit silently without crashing.
# CLAUDE.md should remain unchanged.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -f CLAUDE.md
cat > CLAUDE.md <<'EOF'
# Read Only File
This content must not be modified by the hook.
EOF
chmod 444 CLAUDE.md
# Also make parent dir read-only to prevent atomic-write-via-temp-file
# from succeeding (atomic write needs to create tmp in parent dir).
chmod 555 "$PROJ"
