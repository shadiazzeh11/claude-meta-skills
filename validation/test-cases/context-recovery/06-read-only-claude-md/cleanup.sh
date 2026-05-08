#!/usr/bin/env bash
# Restore writable permissions so harness can run again.
PROJ="$TEST_DIR/project"
chmod 755 "$PROJ" 2>/dev/null || true
chmod 644 "$PROJ/CLAUDE.md" 2>/dev/null || true
