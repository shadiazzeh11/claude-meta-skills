#!/usr/bin/env bash
# Regression test for testing/analyze-log.py.
#
# Builds a temp JSONL log with one entry of each classification, runs the
# analyzer in default, --real-only, and --redact modes, and asserts on the
# output. Does not read or write ~/.claude.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/analyze-log.py"

if [[ ! -x "$ANALYZER" ]] && [[ ! -f "$ANALYZER" ]]; then
    echo "FAIL: analyzer not found at $ANALYZER" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
TEMP_LOG="$WORKDIR/meta-skills-log.jsonl"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Use a current timestamp so all fixtures fall inside the default 7-day window.
TS_BASE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Fixture entries:
#   1. manual/synthetic edit-drift-detector (session_id=manual-test)
#   2. real construction-gate on /private/tmp/foo (canonicalizes to /tmp/foo)
#   3. real completion-verifier on the same UUID session
#   4. harness/validation silent-file-verifier (project under validation/test-cases/)
#   5. unknown context-recovery (non-UUID session id, no harness indicators)
cat > "$TEMP_LOG" <<EOF
{"timestamp":"$TS_BASE","hook":"edit-drift-detector","action":"block-fuzzy","project":"/tmp/foo","detail":"file=src/app.py lines=2 similarity=0.74","session_id":"manual-test"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/private/tmp/foo","detail":"file=/tmp/foo/.env","session_id":"abcdef12-1234-1234-1234-1234567890ab"}
{"timestamp":"$TS_BASE","hook":"completion-verifier","action":"block","project":"/private/tmp/foo","detail":"project_type=Makefile test_exit_code=2","session_id":"abcdef12-1234-1234-1234-1234567890ab"}
{"timestamp":"$TS_BASE","hook":"silent-file-verifier","action":"warn","project":"/Users/dev/repo/validation/test-cases/silent-file-verifier/01-foo","detail":"file=ghost.txt","session_id":"test-session"}
{"timestamp":"$TS_BASE","hook":"context-recovery","action":"modify","project":"/some/other/project","detail":"branch=main","session_id":"local-dev-string"}
EOF

assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if ! grep -qF -- "$needle" <<< "$haystack"; then
        echo "FAIL [$label]: expected to find: $needle" >&2
        echo "--- output ---" >&2
        echo "$haystack" >&2
        echo "--- end ---" >&2
        exit 1
    fi
}

assert_not_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "FAIL [$label]: expected NOT to find: $needle" >&2
        echo "--- output ---" >&2
        echo "$haystack" >&2
        echo "--- end ---" >&2
        exit 1
    fi
}

echo "Test: default output classification + path canonicalization"
DEFAULT_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG")"
assert_contains "default-class-label" "Classification totals (all matching log entries, before --real-only display filter):" "$DEFAULT_OUT"
assert_contains "default-real"     "real dogfood: 2 fires"          "$DEFAULT_OUT"
assert_contains "default-manual"   "manual/synthetic: 1 fires"      "$DEFAULT_OUT"
assert_contains "default-harness"  "harness/validation: 1 fires"    "$DEFAULT_OUT"
assert_contains "default-unknown"  "unknown: 1 fires"               "$DEFAULT_OUT"
assert_contains "default-sessions" "Real Claude Code sessions: 1"   "$DEFAULT_OUT"
assert_contains "default-project"  "/tmp/foo — 3 fires"             "$DEFAULT_OUT"
assert_not_contains "default-no-private-tmp" "/private/tmp/foo"     "$DEFAULT_OUT"

echo "Test: --real-only filter"
REAL_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --real-only)"
assert_contains "real-banner"     "Filter: real dogfood only"        "$REAL_OUT"
assert_contains "real-class-label" "Classification totals (all matching log entries, before --real-only display filter):" "$REAL_OUT"
assert_contains "real-total"      "Total: 2 fires across 2 hooks"    "$REAL_OUT"
assert_contains "real-cg"         "construction-gate"                "$REAL_OUT"
assert_contains "real-cv"         "completion-verifier"              "$REAL_OUT"
assert_contains "real-sessions"   "Real Claude Code sessions: 1"     "$REAL_OUT"
assert_not_contains "real-no-edd" "edit-drift-detector"              "$REAL_OUT"
assert_not_contains "real-no-sfv" "silent-file-verifier"             "$REAL_OUT"
assert_not_contains "real-no-cr"  "context-recovery"                 "$REAL_OUT"

echo "Test: --redact runs cleanly"
REDACT_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --redact)"
if [[ -z "$REDACT_OUT" ]]; then
    echo "FAIL [redact]: --redact produced empty output" >&2
    exit 1
fi

echo "All analyzer tests passed"
