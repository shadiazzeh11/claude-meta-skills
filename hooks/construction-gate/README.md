# construction-gate

PreToolUse hook on Write that blocks writes to protected paths (dependency directories, lock files, sensitive config). Completes the Prevention layer — alongside `edit-drift-detector` (Edit) — for file-modifying operations.

## What it catches

- Writes to dependency directories (`node_modules/`, etc.)
- Writes to `.git/` internals
- Writes to environment files (`.env`, `.env.production`, etc.)
- Writes to package lock files (`package-lock.json`, `yarn.lock`, `bun.lockb`, `Cargo.lock`, `Gemfile.lock`, `poetry.lock`, `uv.lock`)
- Writes to Claude Code's own configuration (`.claude/settings.json`)

## What it intentionally doesn't catch

- **TODO/placeholder content checks** — delegated to specialized tools like `danielmiessler/PAI` which has comprehensive TODO regex coverage. Building a thinner version of their check would be convergent without adding value.
- **File size limits** — high false-positive risk on legitimate large files (data dumps, generated assets, documentation). If you want size enforcement, add a custom regex like `\.gen\.json$` for known-large generated files.
- **Content quality checks** (lint, types, etc.) — covered by `omerkaz/claude-code-ts-quality-hook` for TypeScript and language-specific tools elsewhere. Out of scope for a structural-only check.

## Installation

Add to `.claude/settings.json` (project-level) or `~/.claude/settings.json` (global):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/construction-gate/hook.py\""
          }
        ]
      }
    ]
  }
}
```

Requires Python 3.7+. Uses stdlib only.

## How it works

1. Reads JSON from stdin (PreToolUse payload).
2. Extracts `tool_input.file_path`.
3. Loads protected-path patterns from `rules.json` next to the hook (or built-in defaults if missing).
4. Compiles each pattern; skips invalid regexes silently rather than crashing.
5. Searches the file path against each pattern with `re.search` (matches anywhere in path).
6. First pattern match → exit 2 with constructive stderr feedback.
7. No match → exit 0 (allow write).

## Configuring rules.json

`rules.json` next to the hook script holds the pattern list:

```json
{
  "protected_patterns": [
    "node_modules/",
    "\\.git/",
    "\\.env(?:\\.|$)",
    "src/generated/"
  ]
}
```

- Patterns are Python regex (matched against full path with `re.search`)
- Escape `.` as `\\.` in JSON
- Order doesn't matter; first match wins
- Invalid regexes are silently skipped (the hook doesn't crash)

To add a pattern: edit `rules.json`. To temporarily disable: comment out or remove the pattern, or temporarily disable the hook in settings.json.

## Design decisions

- **Regex matching, not glob.** More expressive (lookahead, alternation, anchors). For users wanting glob-like simplicity, anchored patterns work: `^node_modules/`, `\\.lock$`.
- **`re.search` not `re.fullmatch`.** Matches anywhere in path. Pattern `node_modules/` matches paths like `/Users/x/proj/node_modules/foo/index.js` (anywhere) but not `my-node_modules-notes.txt` (no slash separator). Test 06 verifies the boundary case.
- **Defaults include common cases for Node, Rust, Ruby, Python, Bun.** Project-specific paths should be added by the user.
- **Constructive feedback default.** Tells Claude what matched and how to override (ask user, modify rules.json). Punitive variant exists for A/B testing.
- **Exit code 2 + stderr** for blocking (per Claude Code hooks convention). JSON-based blocking via `permissionDecision: deny` is an alternative if exit 2 reliability issues surface (per GitHub issue #13744 — same risk as edit-drift-detector).
- **Invalid regex → skip pattern, don't crash.** Allows users to add custom patterns without risk of bricking the hook on syntax errors.

## Coexistence with other hooks

- This hook fires PreToolUse on Write. If it blocks (exit 2), `silent-file-verifier`'s PostToolUse does NOT fire (correct — there's no Write to verify when it was prevented).
- Independent of `edit-drift-detector` (different matcher: Write vs Edit).
- Independent of `completion-verifier` and `context-recovery` (different events).

Behavior documented per Claude Code lifecycle docs; not validated by the harness (which tests each hook in isolation).

## Known limitations

- **GitHub issue #13744:** PreToolUse exit 2 has been reported as unreliable for blocking Write/Edit in some Claude Code versions. Same caveat as `edit-drift-detector`. If observed, switch to JSON-based blocking.
- **Path matching is regex, not git-aware.** A pattern like `\.git/` blocks all `.git` paths, including in nested git submodules and bare repos. Generally desirable.
- **No allowlist override.** If a user wants to write to a protected path intentionally (e.g., updating a lock file as part of a controlled refactor), they must temporarily disable the hook or modify `rules.json`. No "this one time only" mechanism.
- **Convergent with ecosystem.** Several tools cover similar ground (`danielmiessler/PAI` for path protection + TODO regex; native Claude Code permission deny rules; `claude-warden` for argument-aware path safety; `snagnever/claude-code-sidecar` for TOML-based policies). Our value is the validation suite + cross-language Python implementation, not the patterns.

## Performance

- Per-fire overhead: ~50-80ms (Python startup + regex compilation + path matching).
- Pattern matching is O(N × M) where N is path length and M is number of patterns; for typical pattern lists (10-20 patterns) this is microseconds.
- See `validation/results/construction-gate-*.json` for measured durations.

## Testing

```bash
cd validation
./harness.sh construction-gate
```

7 test cases covering should-block (3), should-pass (3), edge cases (1). See `validation/test-cases/construction-gate/`.
