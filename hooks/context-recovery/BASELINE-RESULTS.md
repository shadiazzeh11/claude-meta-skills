# Baseline validation — context-recovery

Initial validation from Phase 3 build. Re-run via `cd validation && ./harness.sh context-recovery`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 (Phase 3) |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 8 (6 should-write, 1 should-pass-silently, 1 idempotency) |
| Pass rate | 8 / 8 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 84 ms |
| Min duration / case | 58 ms |
| Max duration / case | 137 ms (test 07 — 200 modified files) |
| Total duration | 675 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | git-repo-with-claude-md | should-write | 0 | 127 | git context captured + appended to existing CLAUDE.md |
| 02 | non-git-directory | should-write | 0 | 60 | reminders + timestamp only; no git fields |
| 03 | no-claude-md | should-write | 0 | 59 | hook creates CLAUDE.md with recovery section |
| 04 | idempotent-replace | should-write | 0 | 58 | existing recovery section replaced, not duplicated; verified count == 1 |
| 05 | content-updates | should-write | 0 | 109 | stale "Branch: stale-branch" replaced with current branch info |
| 06 | read-only-claude-md | should-pass-silently | 0 | 61 | read-only file + read-only parent dir; hook exits 0 without crashing; original unchanged |
| 07 | token-budget | should-write | 0 | 137 | 200 modified files; recovery section truncated to fit ~2000-char budget |
| 08 | claude-project-dir-env | should-write | 0 | 64 | CLAUDE_PROJECT_DIR env var override; hook writes to env path, not cwd |

## Notes on performance

- Median per-case ~85ms. Tests with no git work (02, 03) complete fastest. Tests with full git command suite (01, 05, 07) are slower.
- Test 07 (token budget with 200 files) takes 137ms — git diff with many files is the cost. Still well under 500ms target.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Atomic write via `tempfile.mkstemp` + `os.replace` confirmed to leave original CLAUDE.md untouched on permission errors (test 06).
- Idempotency verified: HTML comment delimiters (`<!-- post-compact-recovery-start -->` / `<!-- post-compact-recovery-end -->`) successfully detect and replace previous recovery sections (tests 04, 05).
- Token budget enforcement: 200 modified files truncated to fit ~2000-char limit with `[truncated — N more files]` marker (test 07).
- `$CLAUDE_PROJECT_DIR` priority over cwd verified (test 08). Real-world relevance: when invoked from project subdirectories, Claude Code sets `$CLAUDE_PROJECT_DIR` to project root and the hook writes there.
- Git repo detection scoped to direct `.git` presence at cwd or `$CLAUDE_PROJECT_DIR` (not walking up parent directories). Prevents picking up unrelated parent-repo context when cwd is a subdirectory of a different git repo.

## Phase 3 design choices

- **PreCompact + CLAUDE.md modification**, not SessionStart:compact. The official docs example uses SessionStart with `"matcher": "compact"` and writes to stdout. That pathway is broken per Claude Code Issue #15174 (hook fires but stdout not injected). CLAUDE.md auto-reload after compaction is the verified working path.
- **HTML comment delimiters** (`<!-- post-compact-recovery-start -->`). Standard markdown convention for invisible markers. Hook reads/writes raw file content, so delimiter visibility in rendered context is irrelevant for hook mechanics.
- **`.git` direct check, not git rev-parse walk-up.** Avoids surfacing wrong git context when cwd is inside an unrelated parent repo. Caught during Phase 3 validation when test 02 (non-git directory) initially failed because the test fixture lived inside the claude-meta-skills repo and parent-repo context bled through.

Per-run JSON written to `validation/results/context-recovery-<timestamp>.json` (gitignored).
