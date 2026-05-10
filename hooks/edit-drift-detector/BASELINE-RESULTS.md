# Baseline validation — edit-drift-detector

Initial validation from Phase 1 build, expanded in Phase 2B (binary-file, relative-path, and protected-path privacy tests). Re-run via `./validation/harness.sh edit-drift-detector`.

| Metric | Value |
|---|---|
| Test date | 2026-05-10 (privacy hardening update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 14 (8 should-block, 6 should-pass) |
| Pass rate | 14 / 14 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 142 ms |
| Min duration / case | 82 ms |
| Max duration / case | 335 ms |
| Total duration | 1992 ms |

## Per-case results

| # | Case | Category | Exit | ms |
|---|---|---|---|---|
| 01 | complete-mismatch | should-block | 2 | 246 |
| 02 | recall-drift | should-block | 2 | 98 |
| 03 | stale-content | should-block | 2 | 171 |
| 04 | whitespace-mismatch | should-block | 2 | 335 |
| 05 | partial-line | should-block | 2 | 194 |
| 06 | exact-match | should-pass | 0 | 164 |
| 07 | multi-line-exact | should-pass | 0 | 177 |
| 08 | whitespace-normalized | should-pass | 0 | 88 |
| 09 | single-line | should-pass | 0 | 90 |
| 10 | large-file (1500 lines) | should-pass | 0 | 83 |
| 11 | binary-file (PNG header) | should-block | 2 | 87 |
| 12 | relative-path-mismatch | should-block | 2 | 88 |
| 13 | protected-env-no-content | should-pass | 0 | 89 |
| 14 | normal-relative-path-under-env-named-cwd | should-block | 2 | 82 |

## Notes on performance

- Performance well under 500ms target across all cases. 1500-line file (case 10) completes in 83ms.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method (the harness invokes `python3 -c "import time; print(time.time()*1000)"` for start/end timestamps, each costing one Python interpreter startup). Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.
- Constructive stderr verified on should-block cases: messages contain similarity score, file content at closest match, and explicit re-read + retry steps.
- Per-run JSON written to `validation/results/edit-drift-detector-<timestamp>.json` (gitignored).

## Phase 2B additions

- **Test 11 (binary file):** PNG header bytes (51 bytes). Hook reads with `errors="replace"`, no match found, blocks with no_close_match path. Verifies the hook doesn't crash on non-text content.
- **Test 12 (relative path mismatch):** Relative `tool_input.file_path` resolves against payload `cwd`; hook reads the intended file and blocks on mismatched `old_string`.
- **Test 13 (protected path privacy):** Relative `.env.local` path resolves against payload `cwd`, matches construction-gate protected patterns, and exits 0 without reading or echoing secret-bearing file content. This is defense in depth for stale/custom hook ordering.
- **Test 14 (cwd false-positive guard):** A normal relative path inside a cwd named `.env.project` still gets drift detection. Protected-path skipping is based on the tool-provided path, not the resolved absolute path.
