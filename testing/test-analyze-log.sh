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
#   1. manual/synthetic edit-drift-detector on /private/tmp/foo (canonicalizes to /tmp/foo)
#   2. real construction-gate under $HOME (proves redaction in session summary)
#   3. real completion-verifier on the same UUID session
#   4. harness/validation silent-file-verifier (session_id=test-session)
#   5. harness/validation construction-gate (UUID session, but validation path)
#   6. unknown context-recovery (non-UUID session id, no harness indicators)
#   7. invalid timestamp line, skipped before classification
cat > "$TEMP_LOG" <<EOF
{"timestamp":"$TS_BASE","hook":"edit-drift-detector","action":"block-fuzzy","project":"/private/tmp/foo","detail":"file=src/app.py lines=2 similarity=0.74","session_id":"manual-test"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"$HOME/code/foo","detail":"file=$HOME/code/foo/.env","session_id":"abcdef12-1234-1234-1234-1234567890ab"}
{"timestamp":"$TS_BASE","hook":"completion-verifier","action":"block","project":"$HOME/code/foo","detail":"project_type=Makefile test_exit_code=2","session_id":"abcdef12-1234-1234-1234-1234567890ab"}
{"timestamp":"$TS_BASE","hook":"silent-file-verifier","action":"warn","project":"/Users/dev/repo/validation/test-cases/silent-file-verifier/01-foo","detail":"file=ghost.txt","session_id":"test-session"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/foo","detail":"file=/Users/dev/repo/validation/test-cases/construction-gate/01-node-modules/project/node_modules/x.js","session_id":"fedcba98-4321-4321-4321-ba0987654321"}
{"timestamp":"$TS_BASE","hook":"context-recovery","action":"modify","project":"/some/other/project","detail":"path=/some/other/project/CLAUDE with spaces.md branch=main","session_id":"local-dev-string"}
{"timestamp":"not-a-timestamp","hook":"construction-gate","action":"block","project":"/tmp/invalid","detail":"file=/tmp/invalid/.env","session_id":"abcdef12-1234-1234-1234-1234567890ab"}
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
assert_contains "default-harness"  "harness/validation: 2 fires"    "$DEFAULT_OUT"
assert_contains "default-unknown"  "unknown: 1 fires"               "$DEFAULT_OUT"
assert_contains "default-sessions" "Real Claude Code sessions: 1"   "$DEFAULT_OUT"
assert_contains "default-invalid-timestamp" "(skipped 1 lines with invalid timestamps)" "$DEFAULT_OUT"
assert_contains "default-noise-note" "Noise note: 4 / 6 fires are non-real. Use --real-only for dogfood evidence." "$DEFAULT_OUT"
assert_contains "default-coverage-observed" "Observed real hooks: construction-gate (1), completion-verifier (1)" "$DEFAULT_OUT"
assert_contains "default-coverage-missing" "Missing real-session evidence: edit-drift-detector, silent-file-verifier, context-recovery" "$DEFAULT_OUT"
assert_contains "default-session-summary" "abcdef12… — 2 fires, 2 hooks (completion-verifier, construction-gate), project=$HOME/code/foo, time=$TS_BASE" "$DEFAULT_OUT"
assert_contains "default-project-canonical"  "/tmp/foo — 2 fires"    "$DEFAULT_OUT"
assert_contains "default-project-home" "$HOME/code/foo — 2 fires"    "$DEFAULT_OUT"
assert_contains "default-path-detail" "/some/other/project/CLAUDE with spaces.md" "$DEFAULT_OUT"
assert_not_contains "default-no-private-tmp" "/private/tmp/foo"     "$DEFAULT_OUT"

echo "Test: --real-only filter"
REAL_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --real-only)"
assert_contains "real-banner"     "Filter: real dogfood only"        "$REAL_OUT"
assert_contains "real-class-label" "Classification totals (all matching log entries, before --real-only display filter):" "$REAL_OUT"
assert_contains "real-total"      "Total: 2 fires across 2 hooks"    "$REAL_OUT"
assert_contains "real-cg"         "construction-gate"                "$REAL_OUT"
assert_contains "real-cv"         "completion-verifier"              "$REAL_OUT"
assert_contains "real-sessions"   "Real Claude Code sessions: 1"     "$REAL_OUT"
assert_contains "real-filter-note" "Display filter removed 4 non-real fires." "$REAL_OUT"
assert_contains "real-coverage-observed" "Observed real hooks: construction-gate (1), completion-verifier (1)" "$REAL_OUT"
assert_contains "real-coverage-missing" "Missing real-session evidence: edit-drift-detector, silent-file-verifier, context-recovery" "$REAL_OUT"
assert_not_contains "real-no-edd-summary" "  edit-drift-detector:"  "$REAL_OUT"
assert_not_contains "real-no-sfv-summary" "  silent-file-verifier:" "$REAL_OUT"
assert_not_contains "real-no-cr-summary"  "  context-recovery:"     "$REAL_OUT"

echo "Test: --redact runs cleanly"
REDACT_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --redact)"
if [[ -z "$REDACT_OUT" ]]; then
    echo "FAIL [redact]: --redact produced empty output" >&2
    exit 1
fi
assert_contains "redact-home-project" "project=~/" "$REDACT_OUT"
assert_not_contains "redact-no-home-project" "project=$HOME/" "$REDACT_OUT"

echo "All analyzer tests passed"
