#!/usr/bin/env bash
HOOK_DIR="$(cd "$TEST_DIR/../../../.." && pwd)/hooks/construction-gate"
if [ -f "$TEST_DIR/rules.json.original" ]; then
  cp "$TEST_DIR/rules.json.original" "$HOOK_DIR/rules.json"
  rm "$TEST_DIR/rules.json.original"
fi
