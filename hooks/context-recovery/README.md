# context-recovery

PreCompact hook that preserves session context through compaction. Captures git state + configurable reminders, writes a recovery section to `CLAUDE.md` (which auto-reloads after compaction). Closes the Context Injection layer (per Crosley's 4-layer framework).

## What it preserves

- Current git branch
- Last 5 git commits
- Modified files (since `HEAD`)
- Configurable static reminders from `rules.json`
- Custom instructions from manual `/compact` invocations

## Architectural choice — why CLAUDE.md modification, not SessionStart:compact

The official docs example for post-compaction context recovery uses a `SessionStart` hook with `"matcher": "compact"` and writes the recovery message to stdout. **This pattern is broken** per Claude Code GitHub issue #15174 — the hook fires but its stdout is NOT injected into Claude's context after compaction. Multiple ecosystem implementations (e.g., `Dicklesworthstone/post_compact_reminder`) use this pattern and ship a hook that fires but does nothing.

The verified working path is CLAUDE.md modification: PreCompact hook writes a recovery section to CLAUDE.md, which auto-reloads after compaction. This is the workaround documented on issue #15174 itself.

Current Claude Code docs list a `PostCompact` event, but this hook intentionally remains `PreCompact`: it writes recovery state before compaction finishes, and this exact path has live-session dogfood evidence. Any redesign around `PostCompact` should first prove the desired post-compaction context-injection behavior in a live Claude Code session.

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

PreCompact has no matcher field (fires on all compaction events: `auto` and `manual`).

**Important:** do not set `"async": true`. Async hooks have a documented macOS stdin bug (issue #38162) that makes the hook receive empty stdin. Default synchronous mode is correct.

Requires Python 3.7+, git, and a writable CLAUDE.md (or a writable project directory if CLAUDE.md doesn't exist yet). Stdlib only.

## How it works

1. Reads JSON from stdin (PreCompact event payload).
2. Resolves CLAUDE.md path: `$CLAUDE_PROJECT_DIR/CLAUDE.md` if env var set, otherwise `cwd/CLAUDE.md`.
3. Runs git commands (with 5-second timeout each, error-tolerant): `branch --show-current`, `log --oneline -5`, `diff --name-only HEAD`.
4. Loads static reminders from `rules.json` next to the hook script.
5. Builds recovery section between `<!-- post-compact-recovery-start -->` and `<!-- post-compact-recovery-end -->` delimiters.
6. Token budget: caps recovery section at ~2000 characters (~500 tokens). Modified-files list is truncated first if over budget.
7. Reads existing CLAUDE.md. If it has a recovery block, replaces it (idempotent). Otherwise, appends.
8. Atomic write: writes to temp file, then `os.replace()`. If the original is locked, read-only, or any step fails, the original is left untouched.

## Design decisions

- **HTML comment delimiters.** Standard markdown convention for invisible markers. Hook reads/writes raw file content, so delimiter visibility in rendered context is irrelevant for mechanics. If Claude sees them in context, they're benign noise.
- **Atomic write.** Uses `tempfile.mkstemp` + `os.replace` (atomic on POSIX). Prevents corruption if the hook crashes mid-write.
- **Idempotent.** Repeated PreCompact events replace the previous recovery section, not append. CLAUDE.md doesn't grow indefinitely.
- **Token budget enforcement.** ~500 tokens max (per Boris Cherny CLAUDE.md guidance: stay well under 5000 total). Modified-files list is the variable-size component; it's truncated first.
- **No CLAUDE.md → create one.** If CLAUDE.md doesn't exist at the resolved path, hook creates a minimal one with just the recovery section. Avoids requiring users to pre-create CLAUDE.md before installing the hook.
- **Read-only file → exit silently.** PermissionError on read or write returns exit 0 without crashing. Better than blowing up before compaction.
- **Exit 0 always.** PreCompact exit 2 has no blocking effect per Claude Code docs. We never try to block compaction.

## Real-session coverage

A controlled local `claude --plugin-dir .` smoke session proved this hook fires from plugin configuration during manual `/compact`: it wrote a Session Recovery block to `CLAUDE.md` containing branch, recent commit, modified files, and the manual compaction sentinel. Treat this as plugin-path lifecycle evidence, not as proof that every future compaction mode or project layout is covered.

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

- **`$CLAUDE_PROJECT_DIR` not set + cwd is subdirectory:** the hook may write to a CLAUDE.md in the wrong location. Workaround: ensure Claude Code is launched from project root, or rely on `$CLAUDE_PROJECT_DIR` being set (Claude Code typically sets it). Fix candidate for future: walk up parent directories looking for an existing CLAUDE.md or `.git` directory.
- **Token budget is approximate.** The 2000-char limit is roughly 500 tokens for English text but actual token count depends on tokenizer. We're within Boris Cherny's recommended 5000-token CLAUDE.md ceiling regardless.
- **HTML comment delimiter behavior in Claude's context window is unverified.** The hook works correctly at the file level (reads/writes raw text). Whether Claude sees the markers in rendered context is unknown but harmless either way.
- **Race condition window with concurrent CLAUDE.md edits.** If a user edits CLAUDE.md in another editor while the hook fires, atomic-write overwrites their unsaved changes. The window is narrow (hook fires on PreCompact only) but real. Mitigation: don't edit CLAUDE.md during long sessions where compaction is likely.
- **PreCompact dependency.** Current Claude Code docs list `PostCompact`, but this hook relies on the dogfooded `PreCompact` + CLAUDE.md reload path. If Claude Code changes the post-compaction reload behavior, this hook would silently stop providing context recovery.
- **Empty git environment.** Outside a git repo, the hook still writes a recovery section with just static reminders + timestamp. No crash.

## Performance

- Per-fire overhead: typically 100-300ms (Python startup + 3 git commands with sub-100ms each).
- Test cases that don't run git commands (non-git directories) complete faster.
- See `validation/results/context-recovery-*.json` for measured durations.

## Testing

```bash
cd validation
./harness.sh context-recovery
```

8 test cases covering should-write (3), idempotency (2), edge cases (3). See `validation/test-cases/context-recovery/`.
