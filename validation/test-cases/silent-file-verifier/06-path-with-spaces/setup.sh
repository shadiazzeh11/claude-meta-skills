#!/usr/bin/env bash
# Create a file at a path containing spaces to verify the hook handles
# path quoting correctly through JSON-stdin → Python argv.
mkdir -p "$TEST_DIR/dir with spaces"
echo "content with spaces in path" > "$TEST_DIR/dir with spaces/file with spaces.txt"
