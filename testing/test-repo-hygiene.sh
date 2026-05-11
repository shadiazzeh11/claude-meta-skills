#!/usr/bin/env bash
# Regression tests for cleanup targets that should not dirty tracked files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RESULTS_DIR="$ROOT/validation/results"
PROBE="$RESULTS_DIR/clean-probe.json"

cleanup() {
  rm -f "$PROBE"
}
trap cleanup EXIT

echo "Test: make clean preserves validation/results/.gitkeep"
mkdir -p "$RESULTS_DIR"
printf '{"probe":true}\n' > "$PROBE"

make clean >/dev/null

if [ ! -f "$RESULTS_DIR/.gitkeep" ]; then
  echo "FAIL: validation/results/.gitkeep missing after make clean" >&2
  exit 1
fi
if [ -e "$PROBE" ]; then
  echo "FAIL: generated validation result survived make clean" >&2
  exit 1
fi
if [ -n "$(git status --short -- validation/results/.gitkeep)" ]; then
  echo "FAIL: make clean dirtied tracked validation/results/.gitkeep" >&2
  git status --short -- validation/results/.gitkeep >&2
  exit 1
fi

echo "All repository hygiene tests passed."
