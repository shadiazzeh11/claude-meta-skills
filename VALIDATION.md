# Validation harness

`validation/harness.sh` runs hook test suites and produces per-run JSON output. It works for any Claude Code hook — not just the five in this repo.

## What it does

For each test case under `validation/test-cases/<hook-name>/<case-name>/`:

1. Optionally runs `setup.sh` to prepare the test environment (with `TEST_DIR` env var pointing at the case directory).
2. Substitutes placeholders in `input.json` (paths to fixtures, project dirs, the test directory itself).
3. Pipes the resulting JSON to the hook's `hook.py` via stdin, with `HOME` set to a per-run temp directory so hook auto-logs do not write to the active dogfood log.
4. Captures exit code, stdout, stderr, and wall-clock duration.
5. Asserts against the fields in `expected.json`.
6. Optionally runs `cleanup.sh`.

Produces a console summary plus a per-run JSON file in `validation/results/`.

The per-run temp `HOME` is removed when the harness exits. Test cases can still override `HOME` explicitly through `expected.json` `env` when a fixture needs to exercise home-directory behavior.

## Directory layout

```
validation/
├── harness.sh
├── results/                          (gitignored — regenerated each run)
│   └── <hook>-<timestamp>.json
└── test-cases/
    └── <hook-name>/
        ├── 01-some-case/
        │   ├── input.json            (required — JSON sent to hook stdin)
        │   ├── expected.json         (required — assertions)
        │   ├── fixture.txt           (optional — substitutes {{FIXTURE_PATH}})
        │   ├── project/              (optional — substitutes {{PROJECT_PATH}})
        │   ├── setup.sh              (optional — runs before hook, executable)
        │   └── cleanup.sh            (optional — runs after hook, executable)
        └── 02-another-case/
            └── ...
```

Test cases run in directory-name sort order, so prefix with `01-`, `02-`, ... if you want a stable ordering in console output.

## input.json — what gets sent to the hook

`input.json` is a literal JSON document piped to the hook's stdin. The harness substitutes these placeholders at runtime:

| Placeholder | Substituted with |
|---|---|
| `{{TEST_DIR}}` | Absolute path of the test case directory |
| `{{FIXTURE_PATH}}` | Absolute path of `fixture.txt` (if it exists) |
| `{{PROJECT_PATH}}` | Absolute path of `project/` directory (if it exists) |
| `{{HOME}}` | Harness temp home; supported in assertion file paths |

Example (from `test-cases/edit-drift-detector/06-exact-match/input.json`):

```json
{
  "session_id": "test-session",
  "tool_name": "Edit",
  "hook_event_name": "PreToolUse",
  "cwd": "{{TEST_DIR}}",
  "tool_input": {
    "file_path": "{{FIXTURE_PATH}}",
    "old_string": "quick brown fox",
    "new_string": "slow green turtle"
  }
}
```

The keys are exactly the keys Claude Code would send to a real hook — see [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) for the per-event schema.

## expected.json — assertions

Every test case must have an `expected_exit_code`. The other fields are optional and additive — combine them as needed.

### Required

```json
{
  "expected_exit_code": 2,
  "description": "should-block: old_str doesn't match file content",
  "category": "should-block"
}
```

`description` and `category` are for human-readable output and aren't asserted, but `category` distinguishes false-positive (`should-pass` got blocked) from false-negative (`should-block` got allowed).

### Stderr / stdout pattern matching

```json
{
  "expected_stderr_contains": [
    "doesn't match",
    "Suggested old_string"
  ],
  "expected_stdout_contains": [
    "additionalContext"
  ],
  "expected_stderr_not_contains": [
    "SECRET_TOKEN"
  ],
  "expected_stdout_not_contains": [
    "SECRET_TOKEN"
  ]
}
```

Each pattern is checked with `grep -q --` (literal substring, not regex). All patterns must match for the test to pass.

Set `expected_stdout_empty: true` or `expected_stderr_empty: true` when a hook is expected to be completely silent on that stream.

`expected_log_not_contains` checks the isolated harness log at `{{HOME}}/.claude/meta-skills-log.jsonl`. Use it for privacy regressions where a secret must not appear in hook metadata.

### File content assertions

Useful for hooks that modify files (like `context-recovery` writing to CLAUDE.md):

```json
{
  "expected_file_contains": {
    "path": "{{TEST_DIR}}/CLAUDE.md",
    "patterns": [
      "post-compact-recovery-start",
      "Branch: main"
    ]
  },
  "expected_file_not_contains": {
    "path": "{{TEST_DIR}}/CLAUDE.md",
    "patterns": [
      "stale-content"
    ]
  },
	  "expected_file_pattern_count": {
	    "path": "{{TEST_DIR}}/CLAUDE.md",
	    "pattern": "post-compact-recovery-start",
	    "count": 1
	  },
	  "expected_file_mode": {
	    "path": "{{HOME}}/.claude/meta-skills-log.jsonl",
	    "mode": "600"
	  },
	  "expected_file_max_chars": {
	    "path": "{{TEST_DIR}}/CLAUDE.md",
	    "max": 2000
	  },
	  "expected_recovery_section_max_chars": {
	    "path": "{{TEST_DIR}}/CLAUDE.md",
	    "max": 2000
	  }
	}
	```

`path` supports `{{TEST_DIR}}`, `{{FIXTURE_PATH}}`, `{{PROJECT_PATH}}`, and `{{HOME}}` placeholders.

`expected_file_pattern_count` is useful for verifying idempotency — e.g., that the recovery hook replaces a previous block rather than appending a duplicate.

`expected_file_mode` uses `stat` to check POSIX permission bits. `expected_recovery_section_max_chars` measures only the block between `post-compact-recovery-start` and `post-compact-recovery-end`, which is useful when the surrounding file may contain unrelated content.

### Environment variables

Inject env vars into the hook process:

```json
{
  "env": {
    "CLAUDE_PROJECT_DIR": "{{TEST_DIR}}/project",
    "COMPLETION_VERIFIER_TIMEOUT_SECS": "5"
  }
}
```

Env values support the same placeholders.

## setup.sh and cleanup.sh

When a test needs runtime state — initializing a git repo, copying a fixture, setting permissions — drop in a `setup.sh` (executable) at the case directory root. The harness sets `TEST_DIR` to the case directory before invoking it.

```bash
#!/usr/bin/env bash
# setup.sh for context-recovery test 04-idempotent-replace
set -e
cat > "$TEST_DIR/CLAUDE.md" <<'EOF'
# My project
<!-- post-compact-recovery-start -->
Old recovery content here.
<!-- post-compact-recovery-end -->
EOF
```

`cleanup.sh` is symmetric — runs after the hook completes. Useful for restoring permissions on read-only fixtures or removing test-generated state that would interfere with the next run.

The harness silences both scripts and tolerates non-zero exits from them (so a missing `cleanup.sh` for a one-shot test isn't a hard error).

## Per-run JSON output

Each invocation writes `validation/results/<hook>-<timestamp>.json` with full structured output:

```json
{
  "hook": "edit-drift-detector",
  "timestamp": "20260502T143022",
  "summary": {
    "pass": 11,
    "fail": 0,
    "total": 11,
    "false_positive": 0,
    "false_negative": 0,
    "total_duration_ms": 567
  },
  "results": [
    {
      "name": "06-exact-match",
      "description": "old_string is an exact substring of file content",
      "category": "should-pass",
      "expected_exit": 0,
      "actual_exit": 0,
      "duration_ms": 51,
      "stdout": "",
      "stderr": "",
      "passed": true,
      "failure_reasons": []
    }
  ]
}
```

Useful for piping into your own local analysis (regression tracking, per-test-case duration trends, CI dashboards). These files are gitignored and regenerated each run; tracked release baselines live in each hook's `BASELINE-RESULTS.md`.

## Validating your own hook

To use the harness for a hook outside this repo:

1. Drop your `hook.py` (or other entry point — but `harness.sh` currently invokes `python3 hook.py`) into `hooks/<your-hook>/hook.py` of a clone of this repo, or set up a symlink from `validation/test-cases/<your-hook>/` and a sibling `hooks/<your-hook>/hook.py`.
2. Create `validation/test-cases/<your-hook>/<NN>-<case-name>/input.json` and `expected.json` for each scenario you want to verify.
3. Run `./validation/harness.sh <your-hook>` from the repo root.

The harness has no dependencies on the rest of the repo — `validation/harness.sh` is self-contained (requires `bash`, `jq`, `python3`, `grep`).

If your hook is invoked differently (e.g., a JavaScript or compiled binary), modify the line in `harness.sh` that runs `python3 "$HOOK_PATH"`. The rest of the assertion machinery is language-agnostic.

## False positive / false negative accounting

The harness distinguishes:

- **False positive**: case category is `should-pass` (`expected_exit_code: 0`) but hook returned `2` (blocked). The hook flagged something it shouldn't have.
- **False negative**: case category is `should-block` (`expected_exit_code: 2`) but hook returned `0` (allowed). The hook missed something it should have caught.

Both are reported separately in the console summary and in the JSON output. We track these as the primary quality metrics rather than just a generic pass-rate, because for hooks the asymmetry matters: a false-positive interrupts the user; a false-negative silently lets bad work through.

## Worked example: testing a new hook

Suppose you write a hook that blocks Edits to files under `/etc/`. Here's a minimal test suite:

```bash
mkdir -p hooks/etc-protector
cat > hooks/etc-protector/hook.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.load(sys.stdin)
path = data.get("tool_input", {}).get("file_path", "")
if path.startswith("/etc/"):
    print(f"Refusing to edit {path}", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
EOF
chmod +x hooks/etc-protector/hook.py

mkdir -p validation/test-cases/etc-protector/01-blocks-etc
cat > validation/test-cases/etc-protector/01-blocks-etc/input.json <<'EOF'
{"tool_name": "Edit", "hook_event_name": "PreToolUse", "tool_input": {"file_path": "/etc/passwd", "old_string": "x", "new_string": "y"}}
EOF
cat > validation/test-cases/etc-protector/01-blocks-etc/expected.json <<'EOF'
{
  "expected_exit_code": 2,
  "description": "should-block: writes under /etc/",
  "category": "should-block",
  "expected_stderr_contains": ["Refusing to edit"]
}
EOF

mkdir -p validation/test-cases/etc-protector/02-allows-elsewhere
cat > validation/test-cases/etc-protector/02-allows-elsewhere/input.json <<'EOF'
{"tool_name": "Edit", "hook_event_name": "PreToolUse", "tool_input": {"file_path": "/tmp/x", "old_string": "x", "new_string": "y"}}
EOF
cat > validation/test-cases/etc-protector/02-allows-elsewhere/expected.json <<'EOF'
{
  "expected_exit_code": 0,
  "description": "should-pass: writes outside /etc/",
  "category": "should-pass"
}
EOF

cd validation && ./harness.sh etc-protector
```

That's the entire surface. Two test cases per hook covers the "blocks the bad thing, allows the good thing" minimum. Add boundary cases (e.g., `/etc/foo` vs filename literally containing the substring `etc`) until you trust the hook.
