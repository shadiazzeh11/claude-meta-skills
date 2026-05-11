# Baseline validation — context-recovery

Initial validation from Phase 3 build, expanded with privacy redaction, hard-cap tests, and subdirectory project-root discovery. Re-run via `cd validation && ./harness.sh context-recovery`.

| Metric | Value |
|---|---|
| Test date | 2026-05-11 (root-discovery hardening update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 13 (12 should-write, 1 should-pass-silently, including one idempotency case) |
| Pass rate | 13 / 13 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 108 ms |
| Min duration / case | 71 ms |
| Max duration / case | 206 ms (test 05 — content-updates) |
| Total duration | 1409 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | git-repo-with-claude-md | should-write | 0 | 144 | git context captured + appended to existing CLAUDE.md |
| 02 | non-git-directory | should-write | 0 | 72 | reminders + timestamp only; no git fields |
| 03 | no-claude-md | should-write | 0 | 117 | hook creates CLAUDE.md at the git project root |
| 04 | idempotent-replace | should-write | 0 | 72 | existing recovery section replaced, not duplicated; verified count == 1 |
| 05 | content-updates | should-write | 0 | 206 | stale "Branch: stale-branch" replaced with current branch info |
| 06 | read-only-claude-md | should-pass-silently | 0 | 71 | read-only file + read-only parent dir; hook exits 0 without crashing; original unchanged |
| 07 | token-budget | should-write | 0 | 150 | 200 modified files; recovery section truncated to fit ~2000-char budget |
| 08 | claude-project-dir-env | should-write | 0 | 73 | CLAUDE_PROJECT_DIR env var override; hook writes to env path, not cwd |
| 09 | custom-instructions-redacted | should-write | 0 | 122 | manual compact instructions redact secret-like assignments while preserving safe sentinel text |
| 10 | custom-instructions-hard-cap | should-write | 0 | 74 | oversized custom instructions cannot push the recovery block beyond the configured hard cap |
| 11 | subdir-existing-claude-md | should-write | 0 | 119 | no env var; nested cwd updates nearest parent CLAUDE.md instead of nested cwd |
| 12 | subdir-git-root-no-claude-md | should-write | 0 | 117 | no env var; nested cwd creates CLAUDE.md at nearest parent git root |
| 13 | env-var-wins-over-parent-discovery | should-write | 0 | 72 | CLAUDE_PROJECT_DIR remains authoritative over parent marker discovery |

## Notes on performance

- Median per-case ~117ms. Tests with no git work (02, 06, 08, 10, 13) complete fastest. Tests with git command suites and fixture setup (01, 03, 05, 07, 11, 12) are slower.
- Test 05 (content-updates) is the max at 206ms in this run. All cases remain under the 500ms target.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Atomic write via `tempfile.mkstemp` + `os.replace` confirmed to leave original CLAUDE.md untouched on permission errors (test 06).
- Idempotency verified: HTML comment delimiters (`<!-- post-compact-recovery-start -->` / `<!-- post-compact-recovery-end -->`) successfully detect and replace previous recovery sections (tests 04, 05).
- Token budget enforcement: 200 modified files truncated to fit ~2000-char limit with `[truncated — N more files]` marker (test 07). If non-file content still exceeds the budget, the final recovery section is hard-capped while preserving the recovery-block delimiters needed for later idempotent replacement (test 10).
- `$CLAUDE_PROJECT_DIR` priority over cwd and parent discovery verified (tests 08, 13). Real-world relevance: when Claude Code sets `$CLAUDE_PROJECT_DIR` to project root, the hook writes there regardless of cwd.
- Subdirectory root discovery verified (tests 11, 12): without `$CLAUDE_PROJECT_DIR`, the hook walks upward from cwd to the nearest existing `CLAUDE.md` or `.git` marker and writes recovery state there.
- Custom compact instructions are sanitized before being written into CLAUDE.md: common secret-like assignments are redacted, long custom text is truncated, and the final section cap is enforced (tests 09, 10).
- Git context is gathered only from the resolved project root when that root directly contains `.git`. This keeps git commands scoped to the chosen root instead of blindly using `git rev-parse` from arbitrary cwd.

## Phase 3 design choices

- **PreCompact + CLAUDE.md modification**, not SessionStart:compact. The official docs example uses SessionStart with `"matcher": "compact"` and writes to stdout. That pathway is broken per Claude Code Issue #15174 (hook fires but stdout not injected). CLAUDE.md auto-reload after compaction is the verified working path.
- **HTML comment delimiters** (`<!-- post-compact-recovery-start -->`). Standard markdown convention for invisible markers. Hook reads/writes raw file content, so delimiter visibility in rendered context is irrelevant for hook mechanics.
- **Nearest project marker root discovery, not raw git rev-parse.** `$CLAUDE_PROJECT_DIR` stays authoritative. Without it, the hook walks upward from cwd and selects the nearest existing `CLAUDE.md` or `.git` marker, then gathers git context only if the selected root directly contains `.git`. This handles subdirectory sessions while avoiding the original Phase 3 parent-repo bleed-through caused by running `git` from arbitrary fixture directories.
- **Best-effort custom instruction redaction.** Manual `/compact` text is useful context, but can contain sensitive content. The hook preserves a bounded excerpt and redacts common `token=`, `api_key=`, `secret=`, `password=`, bearer-token, and `sk-...` shapes.

Per-run JSON written to `validation/results/context-recovery-<timestamp>.json` (gitignored).
