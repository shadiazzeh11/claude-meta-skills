# Baseline validation — completion-verifier

Initial validation from Phase 2 build, expanded in Phase 2.5 (transcript parsing + cargo-missing tests), Phase 2B dogfood follow-up (pytest-configured local-venv projects), the missing-pytest warning regression, timeout-env hardening, subdirectory project-root discovery, and timeout partial-output warnings. Re-run via `cd validation && ./harness.sh completion-verifier`.

| Metric | Value |
|---|---|
| Test date | 2026-05-11 (subdirectory project discovery update) |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| Node | v20.20.2 |
| OS | Darwin 25.3.0 |
| Test cases | 20 (10 should-block, 10 should-pass) |
| Pass rate | 20 / 20 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 318 ms |
| Min duration / case | 101 ms |
| Max duration / case | 2117 ms (test 08 — timeout, waits 2s) |
| Total duration | 6368 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | node-failing | should-block | 0 (block via JSON) | 668 | npm test exits 1 |
| 02 | python-failing | should-block | 0 (block via JSON) | 207 | python -m unittest fails |
| 03 | build-failure | should-block | 0 (block via JSON) | 125 | make test exits 1 |
| 04 | node-passing | should-pass | 0 | 276 | npm test exits 0 |
| 05 | python-passing | should-pass | 0 | 173 | unittest passes |
| 06 | no-project | should-pass | 0 | 104 | git-bounded directory with no recognizable config |
| 07 | stop-hook-active | should-pass | 0 | 104 | anti-loop check returns immediately |
| 08 | timeout | should-pass (warn) | 0 | 2117 | sleep 5 + timeout=2; emits warning with partial pre-timeout output |
| 09 | transcript-with-writes | should-block | 0 (block) | 125 | transcript shows Edit; runs failing tests, blocks |
| 10 | transcript-without-writes | should-pass | 0 | 104 | exploration session: skips tests despite project failing |
| 11 | malformed-transcript | should-block | 0 (block) | 121 | unparseable transcript -> fall back to running tests |
| 12 | cargo-not-installed | should-pass (warn) | 0 | 336 | FileNotFoundError handler emits command-not-found warning |
| 13 | pytest-venv-passing | should-pass | 0 | 669 | pytest-configured pyproject uses local .venv Python and passes |
| 14 | pytest-venv-failing | should-block | 0 (block) | 366 | pytest-configured pyproject uses local .venv Python and blocks on pytest failure |
| 15 | pytest-declared-missing | should-pass (warn) | 0 | 179 | pytest declared but unavailable; emits command-not-found warning without crashing |
| 16 | invalid-timeout-env | should-block | 0 (block) | 162 | invalid `COMPLETION_VERIFIER_TIMEOUT_SECS=abc` falls back to default and blocks failing tests |
| 17 | zero-timeout-env | should-block | 0 (block) | 129 | zero timeout env falls back to default instead of causing immediate timeout |
| 18 | negative-timeout-env | should-block | 0 (block) | 125 | negative timeout env falls back to default instead of crashing or timing out |
| 19 | subdir-python-failing | should-block | 0 (block) | 177 | nested cwd discovers parent pyproject root and blocks on failing tests |
| 20 | subdir-no-project-git-boundary | should-pass | 0 | 101 | nested cwd with `CLAUDE_PROJECT_DIR` set above it stops discovery at nearest git root with no project config |

## Notes on performance

- 17 of 20 cases under 500ms. The exceptions in this run are npm startup (test 01), pytest local-venv startup (test 13), and the intentional timeout (test 08).
- Test 08 (timeout) intentionally waits the configured 2-second timeout. Production deployments using the default 30s timeout would experience up to 30s wall-clock when test commands hang, by design. Invalid, zero, or negative timeout env values fall back to the 30s default.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.
- Anti-loop check (test 07) returns in 104ms in this run — under load this matters because the hook fires on every Stop attempt during forced-continuation.

## Notes on observed behavior

- Stop-hook blocking via JSON `{"decision": "block", "reason": ...}` works as expected. Constructive feedback (last 50 lines of test output + remediation guidance) verified in stdout for blocking cases.
- `stop_hook_active: true` correctly short-circuits before any test execution.
- Test command not found and timeout paths emit `additionalContext` warnings rather than blocking. Timeout warnings include captured partial output when the timed-out process flushed any output before termination. As with failing-test snippets, this output is sent to Claude Code as feedback but is not written to the persistent meta-skills log.
- Transcript parsing critical-path test 10 verifies exploration-session detection: project has failing tests, but transcript shows only Read/Bash/Glob (no writes), so hook skips test execution and exits silently. This was the largest validation gap in the original Phase 2 build.

## Phase 2.5 additions

- **Tests 09-11 (transcript parsing):** Validate the previously-untested transcript_has_writes feature. Test 10 is the load-bearing case (exploration session detection). Test 11 verifies fallback to running tests when transcript is unreadable.
- **Test 12 (cargo-not-installed):** Validates FileNotFoundError handler. The fixture hides Cargo from PATH (via `env.PATH = "/usr/bin:/bin"` in `expected.json`) so the FileNotFoundError path is deterministic both locally and in CI runners that ship Cargo by default. The hook correctly emits a "command not found" `additionalContext` warning.
- **Tests 13-14 (pytest local venv):** Validate pytest-configured `pyproject.toml` projects use an already-installed local `.venv` Python with `-m pytest` instead of system `python3 -m unittest`. This covers the LOGOS dogfood false positive where system Python lacked pytest while the project `.venv` had the correct runner.
- **Test 15 (pytest declared missing):** Validates the warning path for pytest-configured projects when neither a local `.venv` runner nor system `python3 -m pytest` is available. This guards against crashing while constructing the command-not-found warning.
- **Tests 16-18 (timeout env hardening):** Validate malformed, zero, and negative `COMPLETION_VERIFIER_TIMEOUT_SECS` values. All three fall back to the default timeout and still block quickly failing tests rather than crashing at import time or timing out immediately.
- **Tests 19-20 (subdirectory project discovery):** Validate that Stop events from project subdirectories discover the nearest parent project config and run tests there, while a nearest git root with no project config stops discovery before it can leak into unrelated parent tests even when `CLAUDE_PROJECT_DIR` is set above the nested repo.
- **Code change:** transcript_has_writes now distinguishes "transcript parseable but no writes" (returns False → skip tests) from "transcript unreadable" (returns None → run tests). Previously both paths returned False, causing malformed-transcript scenarios to be misclassified as exploration sessions.
- **Code change:** transcript scanner extended to detect `MultiEdit` and `NotebookEdit` (in addition to `Write` and `Edit`) so sessions using batch-edit tools are correctly classified as having writes.
- **Code change:** `COMPLETION_VERIFIER_TIMEOUT_SECS` parsing now fails open to the default for malformed, zero, or negative values.
- **Code change:** project-type detection now resolves a bounded project root before selecting a test command. `$CLAUDE_PROJECT_DIR` acts as the trusted upper bound when present; otherwise discovery stops at the nearest git root.

Per-run JSON written to `validation/results/completion-verifier-<timestamp>.json` (gitignored).
