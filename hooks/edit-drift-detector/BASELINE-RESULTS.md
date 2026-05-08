# Baseline validation — edit-drift-detector

Initial validation from Phase 1 build, expanded in Phase 2.5 (binary file test). Re-run via `cd validation && ./harness.sh edit-drift-detector`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 (Phase 2.5 update) |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 11 (6 should-block, 5 should-pass) |
| Pass rate | 11 / 11 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 51 ms |
| Min duration / case | 48 ms |
| Max duration / case | 61 ms |
| Total duration | 567 ms |

## Per-case results

| # | Case | Category | Exit | ms |
|---|---|---|---|---|
| 01 | complete-mismatch | should-block | 2 | 61 |
| 02 | recall-drift | should-block | 2 | 52 |
| 03 | stale-content | should-block | 2 | 50 |
| 04 | whitespace-mismatch | should-block | 2 | 51 |
| 05 | partial-line | should-block | 2 | 51 |
| 06 | exact-match | should-pass | 0 | 50 |
| 07 | multi-line-exact | should-pass | 0 | 50 |
| 08 | whitespace-normalized | should-pass | 0 | 52 |
| 09 | single-line | should-pass | 0 | 52 |
| 10 | large-file (1500 lines) | should-pass | 0 | 50 |
| 11 | binary-file (PNG header) | should-block | 2 | 48 |

## Notes on performance

- Performance well under 500ms target across all cases. 1500-line file (case 10) completes in 50ms.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method (the harness invokes `python3 -c "import time; print(time.time()*1000)"` for start/end timestamps, each costing one Python interpreter startup). Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.
- Constructive stderr verified on should-block cases: messages contain similarity score, file content at closest match, and explicit re-read + retry steps.
- Per-run JSON written to `validation/results/edit-drift-detector-<timestamp>.json` (gitignored).

## Phase 2.5 additions

- **Test 11 (binary file):** PNG header bytes (51 bytes). Hook reads with `errors="replace"`, no match found, blocks with no_close_match path. Verifies the hook doesn't crash on non-text content. Performance: 48ms.
