# Baseline validation — silent-file-verifier

Initial validation from Phase 2 build, expanded in Phase 2B (MultiEdit/NotebookEdit and relative-path coverage). Re-run via `./validation/harness.sh silent-file-verifier`.

| Metric | Value |
|---|---|
| Test date | 2026-05-09 (Phase 2B dogfood baseline update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 10 (4 should-warn, 6 should-pass) |
| Pass rate | 10 / 10 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 53 ms |
| Min duration / case | 49 ms |
| Max duration / case | 71 ms |
| Total duration | 532 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | missing-file | should-warn | 0 + additionalContext | 71 | Write reported success, file doesn't exist on disk |
| 02 | zero-bytes-with-content | should-warn | 0 + additionalContext | 52 | Write succeeded but file is 0 bytes despite non-empty content |
| 03 | write-with-content | should-pass | 0 (silent) | 55 | normal Write success case |
| 04 | edit-existing | should-pass | 0 (silent) | 53 | Edit success; existence check only (no size check on Edit) |
| 05 | empty-write-empty-content | should-pass | 0 (silent) | 51 | intentional empty Write; 0-byte file is correct |
| 06 | path-with-spaces | should-pass | 0 (silent) | 49 | path containing spaces handled correctly |
| 07 | multiedit-missing | should-warn | 0 + additionalContext | 52 | MultiEdit reported success but file doesn't exist; verifies extended matcher coverage |
| 08 | relative-path-existing | should-pass | 0 (silent) | 49 | Relative file_path resolved against payload cwd; file exists with non-empty content |
| 09 | relative-path-notebook-existing | should-pass | 0 (silent) | 51 | Relative notebook_path resolved against payload cwd; notebook exists |
| 10 | relative-path-missing | should-warn | 0 + additionalContext | 49 | Relative file_path resolved against payload cwd; file genuinely missing under project root |

## Notes on performance

- All cases completed in 49-71ms. Hook is essentially Python startup time + a single `os.path.exists` and (for Write) `os.path.getsize` call.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.
- Performance well under 500ms target across all cases. PostToolUse adds negligible overhead per file write.

## Notes on observed behavior

- `additionalContext` warnings (not blocking decisions) verified in stdout for the three should-warn cases. PostToolUse can't undo, so warning is the right channel.
- Edit operations skip the size check (only existence) per design decision (Edit doesn't have `content` field; can't compute expected size).
- Empty content + 0-byte file = correct (test 05 passes silently). Non-empty content + 0-byte file = ghost-file warning (test 02).
- Path with spaces (test 06) confirms JSON-stdin → Python pathlib path resolution handles whitespace correctly. No shell escaping issues.
- MultiEdit ghost-file detection (test 07) confirms the extended matcher works for batch-edit tools.
- Relative path tests (08-10) confirm `file_path` and `notebook_path` resolution against payload `cwd`.

## Phase 2B additions

- **Test 07 (multiedit-missing):** Validates that the matcher extension to `Write|Edit|MultiEdit|NotebookEdit` works as expected. The hook detects MultiEdit's tool_input.file_path correctly and emits the same missing-file warning as for Write.
- **Tests 08-10 (relative path coverage):** Validate relative `file_path` and `notebook_path` resolution against payload `cwd`, including a missing-file warning for a relative path that does not exist under the project root.
- **Code change:** `file_path` extraction now falls back to `tool_input.notebook_path` if `file_path` is missing (NotebookEdit may use the latter).
- **Settings.json matcher:** users should update from `"Write|Edit"` to `"Write|Edit|MultiEdit|NotebookEdit"` to get coverage on batch-edit tools.

Per-run JSON written to `validation/results/silent-file-verifier-<timestamp>.json` (gitignored).
