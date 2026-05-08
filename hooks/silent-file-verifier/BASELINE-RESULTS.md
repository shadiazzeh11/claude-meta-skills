# Baseline validation — silent-file-verifier

Initial validation from Phase 2 build. Re-run via `cd validation && ./harness.sh silent-file-verifier`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 6 (2 should-warn, 4 should-pass) |
| Pass rate | 6 / 6 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 70 ms |
| Min duration / case | 70 ms |
| Max duration / case | 71 ms |
| Total duration | 423 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | missing-file | should-warn | 0 + additionalContext | 70 | Write reported success, file doesn't exist on disk |
| 02 | zero-bytes-with-content | should-warn | 0 + additionalContext | 70 | Write succeeded but file is 0 bytes despite non-empty content |
| 03 | write-with-content | should-pass | 0 (silent) | 70 | normal Write success case |
| 04 | edit-existing | should-pass | 0 (silent) | 70 | Edit success; existence check only (no size check on Edit) |
| 05 | empty-write-empty-content | should-pass | 0 (silent) | 70 | intentional empty Write; 0-byte file is correct |
| 06 | path-with-spaces | should-pass | 0 (silent) | 71 | path containing spaces handled correctly |

## Notes on performance

- All cases consistently 70-71ms. Hook is essentially Python startup time + a single `os.path.exists` and (for Write) `os.path.getsize` call.
- Performance well under 500ms target across all cases. PostToolUse adds negligible overhead per file write.

## Notes on observed behavior

- `additionalContext` warnings (not blocking decisions) verified in stdout for the two should-warn cases. PostToolUse can't undo, so warning is the right channel.
- Edit operations skip the size check (only existence) per design decision (Edit doesn't have `content` field; can't compute expected size).
- Empty content + 0-byte file = correct (test 05 passes silently). Non-empty content + 0-byte file = ghost-file warning (test 02).
- Path with spaces (test 06) confirms JSON-stdin → Python pathlib path resolution handles whitespace correctly. No shell escaping issues.

Per-run JSON written to `validation/results/silent-file-verifier-<timestamp>.json` (gitignored).
