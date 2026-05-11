# Baseline validation — context-recovery

Initial validation from Phase 3 build, expanded with privacy redaction and hard-cap tests. Re-run via `cd validation && ./harness.sh context-recovery`.

| Metric | Value |
|---|---|
| Test date | 2026-05-10 (privacy hardening update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 10 (9 should-write, 1 should-pass-silently, including one idempotency case) |
| Pass rate | 10 / 10 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 189 ms |
| Min duration / case | 92 ms |
| Max duration / case | 467 ms (test 05 — content-updates) |
| Total duration | 1897 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | git-repo-with-claude-md | should-write | 0 | 205 | git context captured + appended to existing CLAUDE.md |
| 02 | non-git-directory | should-write | 0 | 105 | reminders + timestamp only; no git fields |
| 03 | no-claude-md | should-write | 0 | 193 | hook creates CLAUDE.md with recovery section |
| 04 | idempotent-replace | should-write | 0 | 194 | existing recovery section replaced, not duplicated; verified count == 1 |
| 05 | content-updates | should-write | 0 | 467 | stale "Branch: stale-branch" replaced with current branch info |
| 06 | read-only-claude-md | should-pass-silently | 0 | 92 | read-only file + read-only parent dir; hook exits 0 without crashing; original unchanged |
| 07 | token-budget | should-write | 0 | 252 | 200 modified files; recovery section truncated to fit ~2000-char budget |
| 08 | claude-project-dir-env | should-write | 0 | 96 | CLAUDE_PROJECT_DIR env var override; hook writes to env path, not cwd |
| 09 | custom-instructions-redacted | should-write | 0 | 189 | manual compact instructions redact secret-like assignments while preserving safe sentinel text |
| 10 | custom-instructions-hard-cap | should-write | 0 | 104 | oversized custom instructions cannot push the recovery block beyond the configured hard cap |

## Notes on performance

- Median per-case ~190ms. Tests with no git work (06, 08, 10) complete fastest. Tests with full git command suite (01, 05, 07) are slower.
- Test 07 (token budget with 200 files) takes 252ms in this run. Test 05 is the max at 467ms because it exercises replacement after content changes. Both remain under the 500ms target.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Atomic write via `tempfile.mkstemp` + `os.replace` confirmed to leave original CLAUDE.md untouched on permission errors (test 06).
- Idempotency verified: HTML comment delimiters (`<!-- post-compact-recovery-start -->` / `<!-- post-compact-recovery-end -->`) successfully detect and replace previous recovery sections (tests 04, 05).
- Token budget enforcement: 200 modified files truncated to fit ~2000-char limit with `[truncated — N more files]` marker (test 07). If non-file content still exceeds the budget, the final recovery section is hard-capped while preserving the recovery-block delimiters needed for later idempotent replacement (test 10).
- `$CLAUDE_PROJECT_DIR` priority over cwd verified (test 08). Real-world relevance: when invoked from project subdirectories, Claude Code sets `$CLAUDE_PROJECT_DIR` to project root and the hook writes there.
- Custom compact instructions are sanitized before being written into CLAUDE.md: common secret-like assignments are redacted, long custom text is truncated, and the final section cap is enforced (tests 09, 10).
- Git repo detection scoped to direct `.git` presence at cwd or `$CLAUDE_PROJECT_DIR` (not walking up parent directories). Prevents picking up unrelated parent-repo context when cwd is a subdirectory of a different git repo.

## Phase 3 design choices

- **PreCompact + CLAUDE.md modification**, not SessionStart:compact. The official docs example uses SessionStart with `"matcher": "compact"` and writes to stdout. That pathway is broken per Claude Code Issue #15174 (hook fires but stdout not injected). CLAUDE.md auto-reload after compaction is the verified working path.
- **HTML comment delimiters** (`<!-- post-compact-recovery-start -->`). Standard markdown convention for invisible markers. Hook reads/writes raw file content, so delimiter visibility in rendered context is irrelevant for hook mechanics.
- **`.git` direct check, not git rev-parse walk-up.** Avoids surfacing wrong git context when cwd is inside an unrelated parent repo. Caught during Phase 3 validation when test 02 (non-git directory) initially failed because the test fixture lived inside the claude-meta-skills repo and parent-repo context bled through.
- **Best-effort custom instruction redaction.** Manual `/compact` text is useful context, but can contain sensitive content. The hook preserves a bounded excerpt and redacts common `token=`, `api_key=`, `secret=`, `password=`, bearer-token, and `sk-...` shapes.

Per-run JSON written to `validation/results/context-recovery-<timestamp>.json` (gitignored).
