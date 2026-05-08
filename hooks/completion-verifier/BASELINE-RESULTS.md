# Baseline validation — completion-verifier

Initial validation from Phase 2 build, expanded in Phase 2.5 (transcript parsing + cwd-missing + cargo-missing tests). Re-run via `cd validation && ./harness.sh completion-verifier`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 (Phase 2.5 update) |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| Node | v20.20.2 |
| OS | Darwin 25.3.0 |
| Test cases | 12 (4 should-block, 8 should-pass) |
| Pass rate | 12 / 12 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 268 ms |
| Min duration / case | 52 ms |
| Max duration / case | 2084 ms (test 08 — timeout, waits 2s) |
| Total duration | 3222 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | node-failing | should-block | 0 (block via JSON) | 347 | npm test exits 1 |
| 02 | python-failing | should-block | 0 (block via JSON) | 117 | python -m unittest fails |
| 03 | build-failure | should-block | 0 (block via JSON) | 71 | make test exits 1 |
| 04 | node-passing | should-pass | 0 | 157 | npm test exits 0 |
| 05 | python-passing | should-pass | 0 | 95 | unittest passes |
| 06 | no-project | should-pass | 0 | 52 | no recognizable config |
| 07 | stop-hook-active | should-pass | 0 | 55 | anti-loop check returns immediately |
| 08 | timeout | should-pass (warn) | 0 | 2084 | sleep 5 + timeout=2; emits additionalContext warning |
| 09 | transcript-with-writes | should-block | 0 (block) | 70 | transcript shows Edit; runs failing tests, blocks |
| 10 | transcript-without-writes | should-pass | 0 | 54 | exploration session: skips tests despite project failing |
| 11 | malformed-transcript | should-block | 0 (block) | 65 | unparseable transcript → fall back to running tests |
| 12 | cargo-not-installed | should-pass (warn) | 0 | 55 | FileNotFoundError handler emits command-not-found warning |

## Notes on performance

- 10 of 12 cases under 500ms. The 2 exceptions (test 01 npm at 347ms, test 08 timeout at 2084ms) are dominated by external process behavior, not hook overhead.
- Test 08 (timeout) intentionally waits the configured 2-second timeout. Production deployments using the default 30s timeout would experience up to 30s wall-clock when test commands hang, by design.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.
- Anti-loop check (test 07) returns in 55ms — under load this matters because the hook fires on every Stop attempt during forced-continuation.

## Notes on observed behavior

- Stop-hook blocking via JSON `{"decision": "block", "reason": ...}` works as expected. Constructive feedback (last 50 lines of test output + remediation guidance) verified in stdout for blocking cases.
- `stop_hook_active: true` correctly short-circuits before any test execution.
- Test command not found / timeout / cwd-missing paths all emit `additionalContext` warnings rather than blocking.
- Transcript parsing critical-path test 10 verifies exploration-session detection: project has failing tests, but transcript shows only Read/Bash/Glob (no writes), so hook skips test execution and exits silently. This was the largest validation gap in the original Phase 2 build.

## Phase 2.5 additions

- **Tests 09-11 (transcript parsing):** Validate the previously-untested transcript_has_writes feature. Test 10 is the load-bearing case (exploration session detection). Test 11 verifies fallback to running tests when transcript is unreadable.
- **Test 12 (cargo-not-installed):** Validates FileNotFoundError handler. Cargo is missing on this machine; hook correctly emits "command not found" warning.
- **Code change:** transcript_has_writes now distinguishes "transcript parseable but no writes" (returns False → skip tests) from "transcript unreadable" (returns None → run tests). Previously both paths returned False, causing malformed-transcript scenarios to be misclassified as exploration sessions.
- **Code change:** cwd-missing now emits a distinct warning instead of being misreported as "command not found." Cleaner debugging when cwd resolution fails.
- **Code change:** transcript scanner extended to detect `MultiEdit` and `NotebookEdit` (in addition to `Write` and `Edit`) so sessions using batch-edit tools are correctly classified as having writes.

Per-run JSON written to `validation/results/completion-verifier-<timestamp>.json` (gitignored).
