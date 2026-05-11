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
assert_contains "default-scorecard-label" "Evidence scorecard (real lifecycle evidence, not production FP/FN rate):" "$DEFAULT_OUT"
assert_contains "default-scorecard" "status=partial; hooks=2/5 real; real_fires=2; real_sessions=1; real_projects=1; non_real_ratio=66.7%" "$DEFAULT_OUT"
assert_contains "default-noise-note" "Noise note: 4 / 6 fires are non-real. Use --real-only for dogfood evidence." "$DEFAULT_OUT"
assert_contains "default-coverage-observed" "Observed real hooks: construction-gate (1), completion-verifier (1)" "$DEFAULT_OUT"
assert_contains "default-coverage-missing" "Missing real-session evidence: edit-drift-detector, silent-file-verifier, context-recovery" "$DEFAULT_OUT"
assert_contains "default-recommendations" "Recommendations:" "$DEFAULT_OUT"
assert_contains "default-missing-rec" "[medium] dogfood-coverage: Collect live-session evidence for missing hooks: edit-drift-detector, silent-file-verifier, context-recovery." "$DEFAULT_OUT"
assert_contains "default-noise-rec" "[medium] noise-filtering: Non-real entries dominate or equal the real signal." "$DEFAULT_OUT"
assert_contains "default-unknown-rec" "[low] unknown-entries: Unknown entries are present." "$DEFAULT_OUT"
assert_contains "default-integrity-rec" "[low] log-integrity: Some log lines were skipped" "$DEFAULT_OUT"
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
assert_contains "real-scorecard"  "status=partial; hooks=2/5 real; real_fires=2; real_sessions=1; real_projects=1; non_real_ratio=66.7%" "$REAL_OUT"
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

echo "Test: --format text matches default shape"
TEXT_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --format text)"
assert_contains "text-total" "Total: 6 fires across 5 hooks" "$TEXT_OUT"
assert_contains "text-coverage-missing" "Missing real-session evidence: edit-drift-detector, silent-file-verifier, context-recovery" "$TEXT_OUT"

echo "Test: --format json"
JSON_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --format json)"
JSON_PAYLOAD="$JSON_OUT" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_PAYLOAD"])
assert data["filter"] == "all"
assert data["total_fires"] == 6
assert data["hook_count"] == 5
assert data["classification_totals"]["real dogfood"] == 2
assert data["classification_totals"]["manual/synthetic"] == 1
assert data["classification_totals"]["harness/validation"] == 2
assert data["classification_totals"]["unknown"] == 1
assert data["timestamp_errors"] == 1
assert data["real_session_count"] == 1
assert data["evidence_scorecard"]["status"] == "partial"
assert data["evidence_scorecard"]["expected_hooks"] == 5
assert data["evidence_scorecard"]["observed_real_hooks"] == 2
assert data["evidence_scorecard"]["missing_real_hooks"] == 3
assert data["evidence_scorecard"]["hook_coverage_percent"] == 40.0
assert data["evidence_scorecard"]["real_fires"] == 2
assert data["evidence_scorecard"]["non_real_fires"] == 4
assert data["evidence_scorecard"]["non_real_ratio_percent"] == 66.7
assert data["evidence_scorecard"]["real_project_count"] == 1
assert [item["topic"] for item in data["recommendations"]] == [
    "dogfood-coverage",
    "noise-filtering",
    "unknown-entries",
    "log-integrity",
]
assert data["missing_real_hooks"] == [
    "edit-drift-detector",
    "silent-file-verifier",
    "context-recovery",
]
assert data["observed_real_hooks"] == [
    {"hook": "construction-gate", "count": 1},
    {"hook": "completion-verifier", "count": 1},
]
assert data["top_projects"][0]["path"]
PY

echo "Test: --format json with --real-only"
REAL_JSON_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --real-only --format json)"
JSON_PAYLOAD="$REAL_JSON_OUT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
assert data["filter"] == "real dogfood only"
assert data["total_fires"] == 2
assert data["evidence_scorecard"]["status"] == "partial"
assert data["classification_total"] == 6
assert data["non_real_count"] == 4
assert data["classification_totals"]["unknown"] == 1
PY

echo "Test: --format markdown"
MARKDOWN_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --format markdown)"
assert_contains "markdown-title" "# Meta-skills Hook Fire Report" "$MARKDOWN_OUT"
assert_contains "markdown-executive" "## Executive Summary" "$MARKDOWN_OUT"
assert_contains "markdown-scorecard" "## Evidence Scorecard" "$MARKDOWN_OUT"
assert_contains "markdown-recommendations" "## Recommendations" "$MARKDOWN_OUT"
assert_contains "markdown-hook-summary" "## Hook Summary" "$MARKDOWN_OUT"
assert_contains "markdown-classification" "## Classification" "$MARKDOWN_OUT"
assert_contains "markdown-coverage" "## Real Dogfood Coverage" "$MARKDOWN_OUT"
assert_contains "markdown-caveats" "## Caveats" "$MARKDOWN_OUT"

echo "Test: --output writes report file without stdout"
OUT_FILE="$WORKDIR/report.json"
STDOUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --format json --output "$OUT_FILE")"
if [[ -n "$STDOUT" ]]; then
    echo "FAIL [output-stdout]: expected empty stdout, got: $STDOUT" >&2
    exit 1
fi
python3 - <<'PY' "$OUT_FILE"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
assert data["total_fires"] == 6
assert data["evidence_scorecard"]["status"] == "partial"
PY

echo "Test: redacted JSON"
REDACT_JSON_OUT="$(python3 "$ANALYZER" --log "$TEMP_LOG" --format json --redact)"
assert_contains "redact-json-home" "~/" "$REDACT_JSON_OUT"
assert_not_contains "redact-json-no-home" "$HOME/" "$REDACT_JSON_OUT"

echo "Test: missing log report includes scorecard"
MISSING_LOG="$WORKDIR/does-not-exist.jsonl"
MISSING_TEXT="$(python3 "$ANALYZER" --log "$MISSING_LOG")"
assert_contains "missing-text-error" "No log file at $MISSING_LOG." "$MISSING_TEXT"
assert_contains "missing-text-scorecard" "Evidence scorecard: status=empty; hooks=0/5 real" "$MISSING_TEXT"
MISSING_JSON="$(python3 "$ANALYZER" --log "$MISSING_LOG" --format json)"
JSON_PAYLOAD="$MISSING_JSON" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
assert data["error"] == "log_not_found"
assert data["evidence_scorecard"]["status"] == "empty"
assert data["evidence_scorecard"]["observed_real_hooks"] == 0
assert data["evidence_scorecard"]["missing_real_hooks"] == 5
assert data["recommendations"][0]["topic"] == "dogfood-evidence"
PY
MISSING_MARKDOWN="$(python3 "$ANALYZER" --log "$MISSING_LOG" --format markdown)"
assert_contains "missing-markdown-scorecard" "## Evidence Scorecard" "$MISSING_MARKDOWN"
assert_contains "missing-markdown-recommendations" "## Recommendations" "$MISSING_MARKDOWN"

echo "Test: argument errors"
if python3 "$ANALYZER" --format xml >/dev/null 2>"$WORKDIR/format.err"; then
    echo "FAIL [format-error]: expected --format xml to fail" >&2
    exit 1
fi
assert_contains "format-error-message" "Error: --format expects text, json, or markdown" "$(cat "$WORKDIR/format.err")"
if python3 "$ANALYZER" --format >/dev/null 2>"$WORKDIR/format-missing.err"; then
    echo "FAIL [format-missing]: expected --format without value to fail" >&2
    exit 1
fi
assert_contains "format-missing-message" "Error: --format requires one of" "$(cat "$WORKDIR/format-missing.err")"
if python3 "$ANALYZER" --output >/dev/null 2>"$WORKDIR/output-missing.err"; then
    echo "FAIL [output-missing]: expected --output without value to fail" >&2
    exit 1
fi
assert_contains "output-missing-message" "Error: --output requires a path" "$(cat "$WORKDIR/output-missing.err")"

echo "Test: complete evidence scorecard and info recommendation"
COMPLETE_LOG="$WORKDIR/complete-meta-skills-log.jsonl"
cat > "$COMPLETE_LOG" <<EOF
{"timestamp":"$TS_BASE","hook":"edit-drift-detector","action":"block-fuzzy","project":"/tmp/complete-a","detail":"file=src/app.py","session_id":"11111111-1111-1111-1111-111111111111"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/complete-a","detail":"file=/tmp/complete-a/.env","session_id":"11111111-1111-1111-1111-111111111111"}
{"timestamp":"$TS_BASE","hook":"silent-file-verifier","action":"warn-empty","project":"/tmp/complete-b","detail":"file=/tmp/complete-b/ghost.txt","session_id":"22222222-2222-2222-2222-222222222222"}
{"timestamp":"$TS_BASE","hook":"completion-verifier","action":"block","project":"/tmp/complete-b","detail":"project_type=Makefile","session_id":"22222222-2222-2222-2222-222222222222"}
{"timestamp":"$TS_BASE","hook":"context-recovery","action":"modify","project":"/tmp/complete-c","detail":"path=/tmp/complete-c/CLAUDE.md","session_id":"33333333-3333-3333-3333-333333333333"}
EOF
COMPLETE_JSON="$(python3 "$ANALYZER" --log "$COMPLETE_LOG" --format json)"
JSON_PAYLOAD="$COMPLETE_JSON" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
assert data["evidence_scorecard"]["status"] == "complete"
assert data["evidence_scorecard"]["observed_real_hooks"] == 5
assert data["evidence_scorecard"]["hook_coverage_percent"] == 100.0
assert data["evidence_scorecard"]["real_session_count"] == 3
assert data["evidence_scorecard"]["real_project_count"] == 3
assert data["recommendations"] == [
    {
        "severity": "info",
        "topic": "evidence",
        "message": "Real dogfood evidence covers all expected hooks in this window. Use the redacted Markdown or JSON report as the release evidence artifact.",
    }
]
PY

echo "Test: recommendation ordering for hot paths and context-recovery skips"
RECOMMENDATION_LOG="$WORKDIR/recommendation-meta-skills-log.jsonl"
cat > "$RECOMMENDATION_LOG" <<EOF
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/reco","detail":"file=/tmp/reco/.env","session_id":"44444444-4444-4444-4444-444444444444"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/reco","detail":"file=/tmp/reco/.env","session_id":"44444444-4444-4444-4444-444444444444"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/reco","detail":"file=/tmp/reco/.env","session_id":"44444444-4444-4444-4444-444444444444"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/reco","detail":"file=/tmp/reco/.env","session_id":"44444444-4444-4444-4444-444444444444"}
{"timestamp":"$TS_BASE","hook":"construction-gate","action":"block","project":"/tmp/reco","detail":"file=/tmp/reco/.env","session_id":"44444444-4444-4444-4444-444444444444"}
{"timestamp":"$TS_BASE","hook":"context-recovery","action":"skip-error","project":"/tmp/reco","detail":"path=/tmp/reco/CLAUDE.md","session_id":"55555555-5555-5555-5555-555555555555"}
EOF
RECOMMENDATION_JSON="$(python3 "$ANALYZER" --log "$RECOMMENDATION_LOG" --format json)"
JSON_PAYLOAD="$RECOMMENDATION_JSON" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
assert [item["topic"] for item in data["recommendations"]] == [
    "dogfood-coverage",
    "hot-path",
    "context-recovery",
]
assert data["top_files"][0]["path"] == "/tmp/reco/.env"
PY

echo "All analyzer tests passed"
