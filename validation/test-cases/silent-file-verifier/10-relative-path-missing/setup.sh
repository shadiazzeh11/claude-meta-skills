#!/usr/bin/env bash
# Project dir exists but src/missing.txt does not. Hook receives cwd=$PROJ,
# file_path="src/missing.txt" (relative). Hook should resolve to
# $PROJ/src/missing.txt, find it genuinely missing under the resolved
# project root, and emit a missing-file warning. Locks the case that
# previously passed by accident (process cwd happened to also lack the
# file) so the warning now fires for the correct reason after resolution.
PROJ="$TEST_DIR/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/src"
# intentionally do not create src/missing.txt
