#!/usr/bin/env bash
# Validation harness for Claude Code hooks.
#
# Usage: ./harness.sh <hook-name>
# Example: ./harness.sh edit-drift-detector
#
# For each test case under test-cases/<hook-name>/, or under
# VALIDATION_TEST_DIR_BASE when set:
#   - Optionally runs setup.sh (with TEST_DIR env var set to case directory)
#     and fails the case if setup exits non-zero
#   - Substitutes placeholders in input.json:
#       {{FIXTURE_PATH}} → absolute path of fixture.txt (if present)
#       {{PROJECT_PATH}} → absolute path of project/ directory (if present)
#       {{TEST_DIR}}     → absolute path of the test case directory
#   - Pipes the resulting JSON to the hook's hook.py via stdin
#     (with HOME set to a per-run temp dir so hook logs don't pollute
#      ~/.claude/meta-skills-log.jsonl)
#   - Captures exit code, stdout, stderr, duration
#   - Compares against expected.json fields:
#       expected_exit_code (required)
#       expected_stderr_contains[] (optional)
#       expected_stderr_not_contains[] (optional)
#       expected_stdout_contains[] (optional)
#       expected_stdout_not_contains[] (optional)
#       expected_file_mode {path, mode} (optional)
#       expected_file_max_chars {path, max} (optional)
#       expected_recovery_section_max_chars {path, max} (optional)
#
# Writes per-run results to results/<hook-name>-<timestamp>.json.

set -o pipefail

HOOK_NAME="${1:-edit-drift-detector}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_PATH="$REPO_DIR/hooks/$HOOK_NAME/hook.py"
TEST_DIR_BASE="${VALIDATION_TEST_DIR_BASE:-$SCRIPT_DIR/test-cases/$HOOK_NAME}"
RESULTS_DIR="$SCRIPT_DIR/results"
LOCK_FILE="${VALIDATION_HARNESS_LOCK_FILE:-$SCRIPT_DIR/.harness.lock}"
LOCK_TIMEOUT_SECS="${VALIDATION_HARNESS_LOCK_TIMEOUT_SECS:-60}"
LOCK_ACQUIRED=false

if [ ! -f "$HOOK_PATH" ]; then
  echo "Hook not found: $HOOK_PATH" >&2
  exit 1
fi
if [ ! -d "$TEST_DIR_BASE" ]; then
  echo "Test cases not found: $TEST_DIR_BASE" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required but not installed" >&2
  exit 1
fi

acquire_lock() {
  touch "$LOCK_FILE"
  exec 9<>"$LOCK_FILE"
  if ! python3 - "$LOCK_TIMEOUT_SECS" "$LOCK_FILE" 9 <<'PY'
import fcntl
import os
import sys
import time

timeout = float(sys.argv[1])
lock_file = sys.argv[2]
fd = int(sys.argv[3])
start = time.monotonic()

while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getppid()}\n".encode("utf-8"))
        sys.exit(0)
    except BlockingIOError:
        elapsed = time.monotonic() - start
        if timeout <= 0 or elapsed >= timeout:
            print(f"Validation harness is already running; lock held at {lock_file}", file=sys.stderr)
            print("Set VALIDATION_HARNESS_LOCK_TIMEOUT_SECS to wait longer.", file=sys.stderr)
            sys.exit(1)
        time.sleep(0.2)
PY
  then
    exit 1
  fi

  LOCK_ACQUIRED=true
}

mkdir -p "$RESULTS_DIR"

PASS=0
FAIL=0
FALSE_POSITIVE=0
FALSE_NEGATIVE=0
TOTAL_DURATION_MS=0

RESULTS_TMP="$(mktemp)"
echo "[]" > "$RESULTS_TMP"
HARNESS_HOME="$(mktemp -d /tmp/claude-meta-harness-home.XXXXXX)"

cleanup() {
  rm -f "$RESULTS_TMP" "${RESULTS_TMP}.new"
  rm -rf "$HARNESS_HOME"
  if [ "$LOCK_ACQUIRED" = "true" ]; then
    : > "$LOCK_FILE"
    exec 9>&-
  fi
}
trap cleanup EXIT

acquire_lock
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
RESULTS_FILE="$RESULTS_DIR/$HOOK_NAME-$TIMESTAMP.json"

expand_expected_path() {
  local path="$1"
  local case_dir="$2"
  path="${path//\{\{TEST_DIR\}\}/$case_dir}"
  path="${path//\{\{HOME\}\}/$HARNESS_HOME}"
  if [ -f "$case_dir/fixture.txt" ]; then
    path="${path//\{\{FIXTURE_PATH\}\}/$case_dir/fixture.txt}"
  fi
  if [ -d "$case_dir/project" ]; then
    path="${path//\{\{PROJECT_PATH\}\}/$case_dir/project}"
  fi
  echo "$path"
}

file_mode() {
  local path="$1"
  python3 - "$path" <<'PY'
import os
import stat
import sys

try:
    mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
except OSError:
    raise SystemExit(0)
print(format(mode, "o"))
PY
}

echo "Validation: $HOOK_NAME"
echo "Hook: $HOOK_PATH"
echo "Tests: $TEST_DIR_BASE"
echo "Hook HOME: $HARNESS_HOME"
echo "----------------------------------------"

for case_dir in "$TEST_DIR_BASE"/*/; do
  [ -d "$case_dir" ] || continue
  case_dir="${case_dir%/}"
  case_name="$(basename "$case_dir")"
  input_template="$case_dir/input.json"
  expected="$case_dir/expected.json"

  if [ ! -f "$input_template" ] || [ ! -f "$expected" ]; then
    echo "SKIP $case_name (missing input.json or expected.json)"
    continue
  fi

  # Optional setup script: runs before the hook with TEST_DIR exported.
  # A failing setup means the fixture is invalid, so mark the case failed
  # explicitly instead of letting a missing fixture produce misleading hook
  # results.
  setup_failed=false
  setup_exit=0
  setup_stdout=""
  setup_stderr=""
  if [ -x "$case_dir/setup.sh" ]; then
    setup_stdout_tmp="$(mktemp)"
    setup_stderr_tmp="$(mktemp)"
    set +e
    TEST_DIR="$case_dir" bash "$case_dir/setup.sh" >"$setup_stdout_tmp" 2>"$setup_stderr_tmp"
    setup_exit=$?
    set -e
    setup_stdout="$(cat "$setup_stdout_tmp")"
    setup_stderr="$(cat "$setup_stderr_tmp")"
    rm -f "$setup_stdout_tmp" "$setup_stderr_tmp"
    if [ "$setup_exit" -ne 0 ]; then
      setup_failed=true
    fi
  fi

  # Build input by substituting placeholders
  input_json="$(cat "$input_template")"
  if [ -f "$case_dir/fixture.txt" ]; then
    fixture_path="$case_dir/fixture.txt"
    input_json="${input_json//\{\{FIXTURE_PATH\}\}/$fixture_path}"
  fi
  if [ -d "$case_dir/project" ]; then
    project_path="$case_dir/project"
    input_json="${input_json//\{\{PROJECT_PATH\}\}/$project_path}"
  fi
  input_json="${input_json//\{\{TEST_DIR\}\}/$case_dir}"

  expected_exit="$(jq -r '.expected_exit_code' "$expected")"
  description="$(jq -r '.description' "$expected")"
  category="$(jq -r '.category' "$expected")"

  # Build env var prefix from optional .env field in expected.json.
  # Env values support same placeholders as input.json.
  env_args=()
  while IFS= read -r kv; do
    [ -z "$kv" ] && continue
    kv="${kv//\{\{TEST_DIR\}\}/$case_dir}"
    if [ -f "$case_dir/fixture.txt" ]; then
      kv="${kv//\{\{FIXTURE_PATH\}\}/$case_dir/fixture.txt}"
    fi
    if [ -d "$case_dir/project" ]; then
      kv="${kv//\{\{PROJECT_PATH\}\}/$case_dir/project}"
    fi
    env_args+=("$kv")
  done < <(jq -r '.env // {} | to_entries[]? | "\(.key)=\(.value)"' "$expected" 2>/dev/null)

  # Run hook, capture stdout + stderr separately, with duration. If setup
  # failed, skip hook execution and report the setup output as the case output.
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  if [ "$setup_failed" = "true" ]; then
    actual_exit=125
    actual_stdout="$setup_stdout"
    actual_stderr="$setup_stderr"
  else
    stdout_tmp="$(mktemp)"
    stderr_tmp="$(mktemp)"
    set +e
    # Isolate tests from Claude Code's parent CLAUDE_PROJECT_DIR so cwd-based
    # fixture tests don't leak to the outer repo. Also isolate HOME so hook
    # auto-logs write to this run's temp directory instead of the active dogfood
    # log at ~/.claude/meta-skills-log.jsonl. Test-case .env assignments still
    # override via env_args (env -u VAR VAR=val keeps the explicit value).
    if [ ${#env_args[@]} -gt 0 ]; then
      echo "$input_json" | env -u CLAUDE_PROJECT_DIR HOME="$HARNESS_HOME" "${env_args[@]}" python3 "$HOOK_PATH" >"$stdout_tmp" 2>"$stderr_tmp"
    else
      echo "$input_json" | env -u CLAUDE_PROJECT_DIR HOME="$HARNESS_HOME" python3 "$HOOK_PATH" >"$stdout_tmp" 2>"$stderr_tmp"
    fi
    actual_exit=$?
    set -e
    actual_stdout="$(cat "$stdout_tmp")"
    actual_stderr="$(cat "$stderr_tmp")"
    rm -f "$stdout_tmp" "$stderr_tmp"
  fi
  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  duration=$((end_ms - start_ms))
  TOTAL_DURATION_MS=$((TOTAL_DURATION_MS + duration))

  # Optional cleanup script
  if [ -x "$case_dir/cleanup.sh" ]; then
    TEST_DIR="$case_dir" bash "$case_dir/cleanup.sh" >/dev/null 2>&1 || true
  fi

  # Determine pass/fail
  passed=true
  failure_reasons=()

  if [ "$setup_failed" = "true" ]; then
    passed=false
    failure_reasons+=("setup.sh failed with exit $setup_exit")
  fi

  if [ "$actual_exit" != "$expected_exit" ]; then
    passed=false
    failure_reasons+=("exit code: expected $expected_exit, got $actual_exit")
    if [ "$expected_exit" = "0" ] && [ "$actual_exit" = "2" ]; then
      FALSE_POSITIVE=$((FALSE_POSITIVE + 1))
    elif [ "$expected_exit" = "2" ] && [ "$actual_exit" = "0" ]; then
      FALSE_NEGATIVE=$((FALSE_NEGATIVE + 1))
    fi
  fi

  # Verify expected_stderr_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if ! echo "$actual_stderr" | grep -Fq -- "$pattern"; then
      passed=false
      failure_reasons+=("stderr missing pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stderr_contains[]?' "$expected")

  # Verify expected_stderr_not_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if echo "$actual_stderr" | grep -Fq -- "$pattern"; then
      passed=false
      failure_reasons+=("stderr should NOT contain pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stderr_not_contains[]?' "$expected")

  # Verify expected_stdout_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if ! echo "$actual_stdout" | grep -Fq -- "$pattern"; then
      passed=false
      failure_reasons+=("stdout missing pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stdout_contains[]?' "$expected")

  # Verify expected_stdout_not_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if echo "$actual_stdout" | grep -Fq -- "$pattern"; then
      passed=false
      failure_reasons+=("stdout should NOT contain pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stdout_not_contains[]?' "$expected")

  # Verify expected_stdout_empty (if specified)
  # Distinct from expected_stdout_contains: an empty array there asserts
  # nothing about stdout. Use this field to require stdout be empty.
  expected_stdout_empty="$(jq -r '.expected_stdout_empty // false' "$expected")"
  if [ "$expected_stdout_empty" = "true" ] && [ -n "$actual_stdout" ]; then
    passed=false
    failure_reasons+=("stdout expected empty but was non-empty")
  fi

  # Verify expected_stderr_empty (if specified)
  expected_stderr_empty="$(jq -r '.expected_stderr_empty // false' "$expected")"
  if [ "$expected_stderr_empty" = "true" ] && [ -n "$actual_stderr" ]; then
    passed=false
    failure_reasons+=("stderr expected empty but was non-empty")
  fi

  # Verify expected_log_not_contains against the isolated harness log.
  log_file="$HARNESS_HOME/.claude/meta-skills-log.jsonl"
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if [ -f "$log_file" ] && grep -Fq -- "$pattern" "$log_file"; then
      passed=false
      failure_reasons+=("log should NOT contain pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_log_not_contains[]?' "$expected")

  # Verify expected_file_contains (if specified)
  # Format: { "path": "...", "patterns": ["pattern1", "pattern2"] }
  # Path supports the same placeholders as input.json substitution.
  expected_file_path="$(jq -r '.expected_file_contains.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$expected_file_path" ]; then
    expected_file_path="$(expand_expected_path "$expected_file_path" "$case_dir")"
    if [ ! -f "$expected_file_path" ]; then
      passed=false
      failure_reasons+=("expected_file_contains: file not found at $expected_file_path")
    else
      file_content="$(cat "$expected_file_path")"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if ! echo "$file_content" | grep -Fq -- "$pattern"; then
          passed=false
          failure_reasons+=("file '$expected_file_path' missing pattern: '$pattern'")
        fi
      done < <(jq -r '.expected_file_contains.patterns[]?' "$expected")
    fi
  fi

  # Verify expected_file_not_contains (if specified)
  not_file_path="$(jq -r '.expected_file_not_contains.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$not_file_path" ]; then
    not_file_path="$(expand_expected_path "$not_file_path" "$case_dir")"
    if [ -f "$not_file_path" ]; then
      file_content="$(cat "$not_file_path")"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if echo "$file_content" | grep -Fq -- "$pattern"; then
          passed=false
          failure_reasons+=("file '$not_file_path' should NOT contain pattern: '$pattern'")
        fi
      done < <(jq -r '.expected_file_not_contains.patterns[]?' "$expected")
    fi
    # If file doesn't exist, "not contains" is trivially satisfied.
  fi

  # Verify expected_file_pattern_count (if specified)
  # Format: { "path": "...", "pattern": "...", "count": N }
  count_file_path="$(jq -r '.expected_file_pattern_count.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$count_file_path" ]; then
    count_file_path="$(expand_expected_path "$count_file_path" "$case_dir")"
    count_pattern="$(jq -r '.expected_file_pattern_count.pattern' "$expected")"
    expected_count="$(jq -r '.expected_file_pattern_count.count' "$expected")"
    if [ -f "$count_file_path" ]; then
      # grep -c always prints the count (including "0") to stdout; the ||
      # only suppresses grep's nonzero exit on no-match. Using `|| echo 0`
      # appends a second "0\n" and produces the literal string "0\n0",
      # which then mis-compares against expected counts.
      actual_count="$(grep -Fc -- "$count_pattern" "$count_file_path" || true)"
      if [ "$actual_count" != "$expected_count" ]; then
        passed=false
        failure_reasons+=("file '$count_file_path' has $actual_count occurrences of '$count_pattern', expected $expected_count")
      fi
    else
      passed=false
      failure_reasons+=("expected_file_pattern_count: file not found at $count_file_path")
    fi
  fi

  # Verify expected_file_mode (if specified)
  mode_file_path="$(jq -r '.expected_file_mode.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$mode_file_path" ]; then
    mode_file_path="$(expand_expected_path "$mode_file_path" "$case_dir")"
    expected_mode="$(jq -r '.expected_file_mode.mode' "$expected")"
    if [ ! -e "$mode_file_path" ]; then
      passed=false
      failure_reasons+=("expected_file_mode: file not found at $mode_file_path")
    else
      actual_mode="$(file_mode "$mode_file_path")"
      if [ "$actual_mode" != "$expected_mode" ]; then
        passed=false
        failure_reasons+=("file '$mode_file_path' mode $actual_mode, expected $expected_mode")
      fi
    fi
  fi

  # Verify expected_file_max_chars (if specified)
  max_file_path="$(jq -r '.expected_file_max_chars.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$max_file_path" ]; then
    max_file_path="$(expand_expected_path "$max_file_path" "$case_dir")"
    expected_max="$(jq -r '.expected_file_max_chars.max' "$expected")"
    if [ ! -f "$max_file_path" ]; then
      passed=false
      failure_reasons+=("expected_file_max_chars: file not found at $max_file_path")
    else
      actual_chars="$(wc -m < "$max_file_path" | tr -d ' ')"
      if [ "$actual_chars" -gt "$expected_max" ]; then
        passed=false
        failure_reasons+=("file '$max_file_path' has $actual_chars chars, expected <= $expected_max")
      fi
    fi
  fi

  # Verify expected_recovery_section_max_chars (if specified)
  recovery_file_path="$(jq -r '.expected_recovery_section_max_chars.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$recovery_file_path" ]; then
    recovery_file_path="$(expand_expected_path "$recovery_file_path" "$case_dir")"
    recovery_max="$(jq -r '.expected_recovery_section_max_chars.max' "$expected")"
    if [ ! -f "$recovery_file_path" ]; then
      passed=false
      failure_reasons+=("expected_recovery_section_max_chars: file not found at $recovery_file_path")
    else
      recovery_chars="$(python3 - "$recovery_file_path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(errors="replace")
start = "<!-- post-compact-recovery-start -->"
end = "<!-- post-compact-recovery-end -->"
start_idx = text.find(start)
end_idx = text.find(end, start_idx)
if start_idx == -1 or end_idx == -1:
    print(-1)
else:
    print(len(text[start_idx:end_idx + len(end)]))
PY
)"
      if [ "$recovery_chars" = "-1" ]; then
        passed=false
        failure_reasons+=("recovery section delimiters not found in $recovery_file_path")
      elif [ "$recovery_chars" -gt "$recovery_max" ]; then
        passed=false
        failure_reasons+=("recovery section in '$recovery_file_path' has $recovery_chars chars, expected <= $recovery_max")
      fi
    fi
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
    if [ -n "$actual_stdout" ]; then
      printf "       Actual stdout (first 200 chars):\n"
      echo "$actual_stdout" | head -c 200 | sed 's/^/         /'
      echo
    fi
  fi

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
    --arg stdout "$actual_stdout" \
    --arg stderr "$actual_stderr" \
    --argjson passed "$pass_bool" \
    --argjson reasons "$reasons_json" \
    '{name: $name, description: $desc, category: $cat, expected_exit: $exp_exit, actual_exit: $act_exit, duration_ms: $duration, stdout: $stdout, stderr: $stderr, passed: $passed, failure_reasons: $reasons}')
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

echo
echo "Results: $RESULTS_FILE"

exit "$FAIL"
