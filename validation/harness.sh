#!/usr/bin/env bash
# Validation harness for Claude Code hooks.
#
# Usage: ./harness.sh <hook-name>
# Example: ./harness.sh edit-drift-detector
#
# For each test case under test-cases/<hook-name>/:
#   - Substitutes the absolute path of fixture.txt into input.json (.tool_input.file_path)
#   - Pipes the resulting JSON to the hook's hook.py via stdin
#   - Captures exit code, stderr, and duration
#   - Compares against expected.json (expected_exit_code + expected_stderr_contains)
# Writes per-run results to results/<hook-name>-<timestamp>.json.

set -o pipefail

HOOK_NAME="${1:-edit-drift-detector}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_PATH="$REPO_DIR/hooks/$HOOK_NAME/hook.py"
TEST_DIR="$SCRIPT_DIR/test-cases/$HOOK_NAME"
RESULTS_DIR="$SCRIPT_DIR/results"

if [ ! -f "$HOOK_PATH" ]; then
  echo "Hook not found: $HOOK_PATH" >&2
  exit 1
fi
if [ ! -d "$TEST_DIR" ]; then
  echo "Test cases not found: $TEST_DIR" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required but not installed" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
RESULTS_FILE="$RESULTS_DIR/$HOOK_NAME-$TIMESTAMP.json"

PASS=0
FAIL=0
FALSE_POSITIVE=0
FALSE_NEGATIVE=0
TOTAL_DURATION_MS=0

# Use a temp file for results array to avoid bash array escaping issues
RESULTS_TMP="$(mktemp)"
echo "[]" > "$RESULTS_TMP"

echo "Validation: $HOOK_NAME"
echo "Hook: $HOOK_PATH"
echo "Tests: $TEST_DIR"
echo "----------------------------------------"

# Iterate test case directories in sorted order
for case_dir in "$TEST_DIR"/*/; do
  [ -d "$case_dir" ] || continue
  case_name="$(basename "$case_dir")"
  fixture="${case_dir}fixture.txt"
  input_template="${case_dir}input.json"
  expected="${case_dir}expected.json"

  if [ ! -f "$input_template" ] || [ ! -f "$expected" ] || [ ! -f "$fixture" ]; then
    echo "SKIP $case_name (missing fixture/input/expected)"
    continue
  fi

  # Substitute fixture path into input JSON via jq (safer than sed for arbitrary paths)
  input_json="$(jq --arg p "$fixture" '.tool_input.file_path = $p' "$input_template")"

  expected_exit="$(jq -r '.expected_exit_code' "$expected")"
  description="$(jq -r '.description' "$expected")"
  category="$(jq -r '.category' "$expected")"

  # Run hook, capture exit code, stderr, duration
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  set +e
  actual_stderr="$(echo "$input_json" | python3 "$HOOK_PATH" 2>&1 1>/dev/null)"
  actual_exit=$?
  set -e
  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  duration=$((end_ms - start_ms))
  TOTAL_DURATION_MS=$((TOTAL_DURATION_MS + duration))

  # Determine pass/fail
  passed=true
  failure_reasons=()

  if [ "$actual_exit" != "$expected_exit" ]; then
    passed=false
    failure_reasons+=("exit code: expected $expected_exit, got $actual_exit")
    # Track false positive (blocked when shouldn't) vs false negative (allowed when shouldn't)
    if [ "$expected_exit" = "0" ] && [ "$actual_exit" = "2" ]; then
      FALSE_POSITIVE=$((FALSE_POSITIVE + 1))
    elif [ "$expected_exit" = "2" ] && [ "$actual_exit" = "0" ]; then
      FALSE_NEGATIVE=$((FALSE_NEGATIVE + 1))
    fi
  fi

  # For block cases, verify stderr contains expected patterns
  if [ "$expected_exit" = "2" ]; then
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if ! echo "$actual_stderr" | grep -q -- "$pattern"; then
        passed=false
        failure_reasons+=("stderr missing pattern: '$pattern'")
      fi
    done < <(jq -r '.expected_stderr_contains[]?' "$expected")
  fi

  if $passed; then
    PASS=$((PASS + 1))
    printf "PASS  %-30s (%dms) %s\n" "$case_name" "$duration" "$description"
  else
    FAIL=$((FAIL + 1))
    printf "FAIL  %-30s (%dms) %s\n" "$case_name" "$duration" "$description"
    for r in "${failure_reasons[@]}"; do
      printf "       Reason: %s\n" "$r"
    done
    if [ -n "$actual_stderr" ]; then
      printf "       Actual stderr (first 200 chars):\n"
      echo "$actual_stderr" | head -c 200 | sed 's/^/         /'
      echo
    fi
  fi

  # Append to results JSON
  pass_bool=$([ "$passed" = "true" ] && echo "true" || echo "false")
  if [ ${#failure_reasons[@]} -eq 0 ]; then
    reasons_json="[]"
  else
    reasons_json=$(printf '%s\n' "${failure_reasons[@]}" | jq -R . | jq -s .)
  fi
  new_entry=$(jq -n \
    --arg name "$case_name" \
    --arg desc "$description" \
    --arg cat "$category" \
    --argjson exp_exit "$expected_exit" \
    --argjson act_exit "$actual_exit" \
    --argjson duration "$duration" \
    --arg stderr "$actual_stderr" \
    --argjson passed "$pass_bool" \
    --argjson reasons "$reasons_json" \
    '{name: $name, description: $desc, category: $cat, expected_exit: $exp_exit, actual_exit: $act_exit, duration_ms: $duration, stderr: $stderr, passed: $passed, failure_reasons: $reasons}')
  jq --argjson e "$new_entry" '. + [$e]' "$RESULTS_TMP" > "${RESULTS_TMP}.new" && mv "${RESULTS_TMP}.new" "$RESULTS_TMP"
done

TOTAL=$((PASS + FAIL))
echo "----------------------------------------"
echo "Total: $TOTAL  Passed: $PASS  Failed: $FAIL"
echo "False positives (blocked when should pass): $FALSE_POSITIVE"
echo "False negatives (allowed when should block): $FALSE_NEGATIVE"
if [ "$TOTAL" -gt 0 ]; then
  AVG_DURATION=$((TOTAL_DURATION_MS / TOTAL))
  echo "Avg duration: ${AVG_DURATION}ms  Total: ${TOTAL_DURATION_MS}ms"
fi

# Write results JSON
results_array=$(cat "$RESULTS_TMP")
jq -n \
  --arg hook "$HOOK_NAME" \
  --arg ts "$TIMESTAMP" \
  --argjson pass "$PASS" \
  --argjson fail "$FAIL" \
  --argjson total "$TOTAL" \
  --argjson fp "$FALSE_POSITIVE" \
  --argjson fn "$FALSE_NEGATIVE" \
  --argjson total_dur "$TOTAL_DURATION_MS" \
  --argjson results "$results_array" \
  '{hook: $hook, timestamp: $ts, summary: {pass: $pass, fail: $fail, total: $total, false_positive: $fp, false_negative: $fn, total_duration_ms: $total_dur}, results: $results}' \
  > "$RESULTS_FILE"

rm -f "$RESULTS_TMP"
echo
echo "Results: $RESULTS_FILE"

exit "$FAIL"
