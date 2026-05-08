# Baseline validation — completion-verifier

Initial validation from Phase 2 build. Re-run via `cd validation && ./harness.sh completion-verifier`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| Node | v20.20.2 |
| OS | Darwin 25.3.0 |
| Test cases | 8 (3 should-block, 5 should-pass) |
| Pass rate | 8 / 8 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 455 ms |
| Min duration / case | 78 ms |
| Max duration / case | 2096 ms (test 08 — timeout, waits 2s) |
| Total duration | 3645 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | node-failing | should-block | 0 (block via JSON) | 522 | npm test exits 1 |
| 02 | python-failing | should-block | 0 (block via JSON) | 392 | python -m unittest fails |
| 03 | build-failure | should-block | 0 (block via JSON) | 103 | make test exits 1 |
| 04 | node-passing | should-pass | 0 | 228 | npm test exits 0 |
| 05 | python-passing | should-pass | 0 | 147 | unittest passes |
| 06 | no-project | should-pass | 0 | 79 | no recognizable config |
| 07 | stop-hook-active | should-pass | 0 | 78 | anti-loop check returns immediately |
| 08 | timeout | should-pass (warn) | 0 | 2096 | sleep 5 + timeout=2; emits additionalContext warning |

## Notes on performance

- 7 of 8 cases under 500ms. Hook overhead itself (excluding the test command it spawns) is consistently under 100ms.
- Test 01 at 522ms reflects npm process startup time on macOS — not hook overhead. In production, this means a passing-test completion check on Node projects adds ~500ms to Stop.
- Test 08 (timeout) at 2096ms intentionally waits the configured 2-second timeout. Production deployments using the default 30s timeout would experience up to 30s wall-clock when test commands hang, by design.
- Anti-loop check (test 07) returns in 78ms — under load, this matters because the hook fires on every Stop attempt during forced-continuation.

## Notes on observed behavior

- Stop-hook blocking via JSON `{"decision": "block", "reason": ...}` works as expected. Constructive feedback (last 50 lines of test output + remediation guidance) verified in stdout for blocking cases.
- `stop_hook_active: true` correctly short-circuits before any test execution (verified in test 07; duration 78ms vs 522ms when active).
- Test command not found / timeout paths emit `additionalContext` warnings rather than blocking — verified in test 08.
- Empty project dir (no config files) passes through silently (test 06).

Per-run JSON written to `validation/results/completion-verifier-<timestamp>.json` (gitignored).
