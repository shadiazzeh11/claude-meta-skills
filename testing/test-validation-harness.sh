#!/usr/bin/env bash
# Regression tests for validation/harness.sh behavior beyond normal hook cases.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP_ROOT="$(mktemp -d /tmp/claude-meta-harness-behavior.XXXXXX)"
TEST_CASES_DIR="$TMP_ROOT/test-cases/edit-drift-detector"
CASE_DIR="$TEST_CASES_DIR/99-setup-failure-probe"
OUT_FILE="$TMP_ROOT/out.txt"
ERR_FILE="$TMP_ROOT/err.txt"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "Test: setup.sh failure marks validation case failed"
mkdir -p "$CASE_DIR"
cat > "$CASE_DIR/input.json" <<'JSON'
{
  "session_id": "test-session",
  "tool_name": "Edit",
  "hook_event_name": "PreToolUse",
  "cwd": "{{TEST_DIR}}",
  "tool_input": {
    "file_path": "{{FIXTURE_PATH}}",
    "old_string": "expected text",
    "new_string": "replacement text"
  }
}
JSON
cat > "$CASE_DIR/expected.json" <<'JSON'
{
  "expected_exit_code": 0,
  "expected_stdout_empty": true,
  "expected_stderr_empty": true,
  "description": "intentional failing setup probe",
  "category": "should-pass"
}
JSON
cat > "$CASE_DIR/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "intentional setup failure" >&2
exit 42
EOF
chmod +x "$CASE_DIR/setup.sh"

if VALIDATION_TEST_DIR_BASE="$TEST_CASES_DIR" ./validation/harness.sh edit-drift-detector >"$OUT_FILE" 2>"$ERR_FILE"; then
  echo "FAIL: harness unexpectedly passed with a failing setup.sh" >&2
  exit 1
fi
grep -F "99-setup-failure-probe" "$OUT_FILE" >/dev/null
grep -F "setup.sh failed with exit 42" "$OUT_FILE" >/dev/null
grep -F "intentional setup failure" "$OUT_FILE" >/dev/null

if [ -e "$ROOT/validation/test-cases/edit-drift-detector/99-setup-failure-probe" ]; then
  echo "FAIL: behavior probe leaked into shared validation fixtures" >&2
  exit 1
fi

echo "All validation harness behavior tests passed."
