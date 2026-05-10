#!/usr/bin/env bash
# Regression: the cwd can contain a protected-looking segment while the
# tool-provided relative path is a normal source file. edit-drift-detector
# should still inspect src/app.js and catch stale old_string drift.
PROJ="$TEST_DIR/.env.project"
rm -rf "$PROJ"
mkdir -p "$PROJ/src"
printf 'const price = 10;\n' > "$PROJ/src/app.js"
