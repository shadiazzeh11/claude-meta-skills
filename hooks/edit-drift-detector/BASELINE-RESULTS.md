# Baseline validation — edit-drift-detector

Initial validation from Phase 1 build. Re-run via `cd validation && ./harness.sh edit-drift-detector`.

| Metric | Value |
|---|---|
| Test date | 2026-05-07 |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 10 (5 should-block, 5 should-pass) |
| Pass rate | 10 / 10 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 51 ms |
| Min duration / case | 49 ms |
| Max duration / case | 58 ms |
| Total duration | 514 ms |

## Per-case results

| # | Case | Category | Exit | ms |
|---|---|---|---|---|
| 01 | complete-mismatch | should-block | 2 | 58 |
| 02 | recall-drift | should-block | 2 | 49 |
| 03 | stale-content | should-block | 2 | 51 |
| 04 | whitespace-mismatch | should-block | 2 | 51 |
| 05 | partial-line | should-block | 2 | 50 |
| 06 | exact-match | should-pass | 0 | 51 |
| 07 | multi-line-exact | should-pass | 0 | 50 |
| 08 | whitespace-normalized | should-pass | 0 | 52 |
| 09 | single-line | should-pass | 0 | 51 |
| 10 | large-file (1500 lines) | should-pass | 0 | 51 |

## Notes

- Performance well under 500ms target across all cases. 1500-line file (case 10) completes in 51ms.
- Constructive stderr verified on should-block cases: messages contain similarity score, file content at closest match, and explicit re-read + retry steps.
- Per-run JSON written to `validation/results/edit-drift-detector-<timestamp>.json` (gitignored).
