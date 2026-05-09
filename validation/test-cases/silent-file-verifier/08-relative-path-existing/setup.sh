#!/usr/bin/env bash
# Project with src/written.txt that exists with non-empty content. Hook
# receives cwd=$PROJ, file_path="src/written.txt" (relative). Hook should
# resolve to $PROJ/src/written.txt, find it exists with non-zero size,
# and exit silently (no missing-file warning).
PROJ="$TEST_DIR/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/src"
printf 'hello\n' > "$PROJ/src/written.txt"
