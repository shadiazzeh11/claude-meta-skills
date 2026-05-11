#!/usr/bin/env bash
# Regression test for validation/harness.sh locking.
#
# The harness setup scripts write under shared validation/test-cases/*/project/
# directories. Running two harnesses in the same checkout at the same time can
# corrupt those fixtures. This verifies the harness uses a repo-local advisory
# lock and can proceed when a stale lock file exists but is not locked.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCK_ROOT="$(mktemp -d /tmp/claude-meta-harness-lock.XXXXXX)"
LOCK_FILE="$LOCK_ROOT/harness.lock"
OUT_FILE="$LOCK_ROOT/out.txt"
ERR_FILE="$LOCK_ROOT/err.txt"

cleanup() {
  rm -rf "$LOCK_ROOT"
}
trap cleanup EXIT

echo "Test: held lock fails quickly"
exec 9>"$LOCK_FILE"
python3 - 9 <<'PY'
import fcntl
import sys

fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)
PY
if VALIDATION_HARNESS_LOCK_FILE="$LOCK_FILE" VALIDATION_HARNESS_LOCK_TIMEOUT_SECS=0 ./validation/harness.sh edit-drift-detector >"$OUT_FILE" 2>"$ERR_FILE"; then
  echo "FAIL: harness unexpectedly ran while lock was held" >&2
  exit 1
fi
grep -F "Validation harness is already running" "$ERR_FILE" >/dev/null
exec 9>&-

echo "Test: stale lock file does not block"
echo "stale" > "$LOCK_FILE"
VALIDATION_HARNESS_LOCK_FILE="$LOCK_FILE" VALIDATION_HARNESS_LOCK_TIMEOUT_SECS=2 ./validation/harness.sh edit-drift-detector >/dev/null
if [ ! -f "$LOCK_FILE" ]; then
  echo "FAIL: harness lock file should remain available for future advisory locks" >&2
  exit 1
fi

echo "Test: waiting lock proceeds after release"
exec 9>"$LOCK_FILE"
python3 - 9 <<'PY'
import fcntl
import sys

fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)
PY
VALIDATION_HARNESS_LOCK_FILE="$LOCK_FILE" VALIDATION_HARNESS_LOCK_TIMEOUT_SECS=5 ./validation/harness.sh silent-file-verifier >"$OUT_FILE" 2>"$ERR_FILE" &
waiter_pid="$!"
sleep 1
exec 9>&-
if ! wait "$waiter_pid"; then
  echo "FAIL: waiting harness did not proceed after lock release" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

echo "Test: free lock allows harness"
VALIDATION_HARNESS_LOCK_FILE="$LOCK_FILE" ./validation/harness.sh construction-gate >/dev/null
if [ ! -f "$LOCK_FILE" ]; then
  echo "FAIL: harness lock file should remain available after second successful run" >&2
  exit 1
fi

echo "All validation harness lock tests passed."
