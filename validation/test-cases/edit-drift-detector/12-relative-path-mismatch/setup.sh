#!/usr/bin/env bash
# Project with src/app.js. Hook receives cwd=$PROJ and file_path="src/app.js"
# (relative). Hook should resolve to $PROJ/src/app.js, see that the
# old_string "const cost = 10;" doesn't match the actual content
# "const price = 10;\n", and block with mismatch feedback.
PROJ="$TEST_DIR/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/src"
printf 'const price = 10;\n' > "$PROJ/src/app.js"
