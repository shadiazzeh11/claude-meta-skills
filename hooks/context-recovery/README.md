# context-recovery

PreCompact hook that preserves session context through compaction. Captures git state + configurable reminders, writes a recovery section to `CLAUDE.md` (which auto-reloads after compaction). Closes the Context Injection layer (per Crosley's 4-layer framework).

## What it preserves

- Current git branch
- Last 5 git commits
- In-progress files: tracked changes plus untracked non-ignored files
- Configurable static reminders from `rules.json`
- A sanitized, bounded excerpt of custom instructions from manual `/compact` invocations

## Architectural choice — why CLAUDE.md modification, not SessionStart/PostCompact injection

Earlier Claude Code guidance and ecosystem examples for post-compaction context recovery used a `SessionStart` hook with `"matcher": "compact"` and wrote the recovery message to stdout. That pathway has had documented failures: Claude Code GitHub issue #15174 reports that the hook fires but stdout is not injected into Claude's context after compaction.

The verified working path in this repo is CLAUDE.md modification: a PreCompact hook writes a recovery section to CLAUDE.md, which auto-reloads after compaction. This is the workaround documented on issue #15174 itself and the path covered by live dogfood.

Current Claude Code docs list both `PreCompact` and `PostCompact`. This hook intentionally remains `PreCompact`: it writes recovery state before compaction finishes, and this exact path has live-session dogfood evidence. Any redesign around `PostCompact` or `SessionStart` context injection should first prove the desired post-compaction context-delivery behavior in a live Claude Code session.

## Installation

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/context-recovery/hook.py\""
          }
        ]
      }
    ]
  }
}
```

PreCompact supports `manual` and `auto` matchers in current Claude Code. This hook intentionally omits a matcher so it runs for both manual `/compact` and auto-compaction.

**Important:** do not set `"async": true`. Async hooks have a documented macOS stdin bug (issue #38162) that makes the hook receive empty stdin. Default synchronous mode is correct.

Requires Python 3.7+, git, and a writable CLAUDE.md (or a writable project directory if CLAUDE.md doesn't exist yet). Stdlib only.

## How it works

1. Reads JSON from stdin (PreCompact event payload).
2. Resolves project root: `$CLAUDE_PROJECT_DIR` if set, otherwise walks upward from `cwd` to the nearest existing `CLAUDE.md` or `.git`, falling back to `cwd` for plain scratch directories.
3. Writes recovery state to `CLAUDE.md` at that resolved root.
4. Runs git commands from the resolved root when it directly contains `.git` (with 5-second timeout each, error-tolerant): `branch --show-current`, `log --oneline -5`, `diff --name-only HEAD`, and `ls-files --others --exclude-standard`.
5. Loads static reminders from `rules.json` next to the hook script.
6. Sanitizes custom instructions: collapses whitespace, redacts common secret/token/password assignments, and truncates to a bounded excerpt.
7. Builds recovery section between `<!-- post-compact-recovery-start -->` and `<!-- post-compact-recovery-end -->` delimiters.
8. Token budget: caps recovery section at ~2000 characters (~500 tokens). The in-progress file list is truncated first if over budget; if reminders/custom instructions still exceed the budget, the final section is hard-capped while preserving the recovery-block delimiters needed for later idempotent replacement.
9. Reads existing CLAUDE.md. If it has a recovery block, replaces it (idempotent). Otherwise, appends.
10. Atomic write: writes to temp file, then `os.replace()`. If the original is locked, read-only, or any step fails, the original is left untouched.

## Design decisions

- **HTML comment delimiters.** Standard markdown convention for invisible markers. Hook reads/writes raw file content, so delimiter visibility in rendered context is irrelevant for mechanics. If Claude sees them in context, they're benign noise.
- **Atomic write.** Uses `tempfile.mkstemp` + `os.replace` (atomic on POSIX). Prevents corruption if the hook crashes mid-write.
- **Nearest project marker discovery.** `$CLAUDE_PROJECT_DIR` stays authoritative. Without it, the hook walks upward from `cwd` and selects the nearest existing `CLAUDE.md` or `.git` marker. This handles subdirectory Claude Code sessions while avoiding a blind `git rev-parse` walk that can surface unrelated parent-repo context.
- **Idempotent.** Repeated PreCompact events replace the previous recovery section, not append. CLAUDE.md doesn't grow indefinitely.
- **Token budget enforcement.** ~500 tokens max (per Boris Cherny CLAUDE.md guidance: stay well under 5000 total). The in-progress file list is the variable-size component; it's truncated first, then the final recovery section is hard-capped if any other content still exceeds the budget. If an impossible tiny cap is configured, delimiter preservation wins so future compactions can still replace the block cleanly.
- **Custom instruction privacy.** Manual `/compact` text can contain sensitive operational notes. The hook preserves only a sanitized excerpt, redacts common secret-like assignments, and truncates long text before writing to CLAUDE.md.
- **No CLAUDE.md → create one.** If CLAUDE.md doesn't exist at the resolved path, hook creates a minimal one with just the recovery section. Avoids requiring users to pre-create CLAUDE.md before installing the hook.
- **Read-only file → exit silently.** PermissionError on read or write returns exit 0 without crashing. Better than blowing up before compaction.
- **Exit 0 always.** Claude Code supports PreCompact decision control, but this hook never tries to block compaction.

## Real-session coverage

A controlled local `claude --plugin-dir .` smoke session proved this hook fires from plugin configuration during manual `/compact`: it wrote a Session Recovery block to `CLAUDE.md` containing branch, recent commit, in-progress files, and the manual compaction sentinel. Treat this as plugin-path lifecycle evidence, not as proof that every future compaction mode or project layout is covered.

## Configuring rules.json

`rules.json` next to the hook script holds project-specific reminders that get included in every recovery section:

```json
{
  "reminders": [
    "Use Bun, not npm",
    "Run tests before declaring task complete",
    "Don't modify production secrets directly"
  ]
}
```

If `rules.json` is missing, malformed, or has no `reminders` array, the hook silently uses an empty list. Recovery section will still include git state and timestamp.

## Coexistence with other hooks

- This hook fires only on PreCompact; independent of all PreToolUse, PostToolUse, and Stop hooks.
- It modifies CLAUDE.md as a side effect. Other hooks that READ CLAUDE.md (none currently in this repo) would see the modified content on subsequent reads.
- Phase 3+ if we add hooks that modify CLAUDE.md for other purposes, we'd need to coordinate delimiter conventions to avoid collisions.

Behavior documented per Claude Code lifecycle docs; not validated by the harness (which tests each hook in isolation).

## Known limitations

- **Parent-marker ambiguity.** If `$CLAUDE_PROJECT_DIR` is absent, root discovery chooses the nearest parent `CLAUDE.md` or `.git` marker. That is correct for normal project subdirectories, but unusual nested-repo or monorepo layouts may prefer a different root. Launch Claude Code from the intended root or rely on `$CLAUDE_PROJECT_DIR` when precision matters.
- **Token budget is approximate.** The 2000-char limit is roughly 500 tokens for English text but actual token count depends on tokenizer. The character cap is enforced, but exact token count is not.
- **Custom instruction redaction is best effort.** The hook redacts common `token=`, `api_key=`, `secret=`, `password=`, bearer-token, and `sk-...` shapes. It cannot guarantee every possible secret format is removed. Avoid putting sensitive material in `/compact` instructions if CLAUDE.md is tracked.
- **HTML comment delimiter behavior in Claude's context window is unverified.** The hook works correctly at the file level (reads/writes raw text). Whether Claude sees the markers in rendered context is unknown but harmless either way.
- **Race condition window with concurrent CLAUDE.md edits.** If a user edits CLAUDE.md in another editor while the hook fires, atomic-write overwrites their unsaved changes. The window is narrow (hook fires on PreCompact only) but real. Mitigation: don't edit CLAUDE.md during long sessions where compaction is likely.
- **PreCompact dependency.** Current Claude Code docs list `PostCompact`, but this hook relies on the dogfooded `PreCompact` + CLAUDE.md reload path. If Claude Code changes the post-compaction reload behavior, this hook would silently stop providing context recovery.
- **Ignored files excluded.** The in-progress file list includes tracked changes and untracked files that Git does not ignore. Ignored files stay out via `git ls-files --others --exclude-standard`, which avoids dumping build outputs, caches, or ignored local secret files into `CLAUDE.md`.
- **Empty git environment.** Outside a git repo, the hook still writes a recovery section with just static reminders + timestamp. No crash.

## Performance

- Per-fire overhead: typically 100-300ms (Python startup + 3 git commands with sub-100ms each).
- Test cases that don't run git commands (non-git directories) complete faster.
- Tracked timing snapshots live in `hooks/context-recovery/BASELINE-RESULTS.md`; local per-run JSON files in `validation/results/` are gitignored and regenerated.

## Testing

```bash
cd validation
./harness.sh context-recovery
```

14 test cases covering should-write, idempotency, privacy redaction, hard-cap behavior, subdirectory root discovery, tracked + untracked file recovery, and edge cases. See `validation/test-cases/context-recovery/`.
