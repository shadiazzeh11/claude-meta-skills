# construction-gate

PreToolUse hook on `Write|Edit|MultiEdit|NotebookEdit` that blocks file modifications to protected paths (dependency directories, lock files, sensitive config). Completes the Prevention layer — alongside `edit-drift-detector` (Edit-only fuzzy-match guidance) — for file-modifying operations.

## What it catches

- Modifications to dependency directories (`node_modules/`, etc.)
- Modifications to `.git/` internals
- Modifications to environment files (`.env`, `.env.production`, etc.)
- Modifications to package lock files (`package-lock.json`, `yarn.lock`, `bun.lockb`, `pnpm-lock.yaml`, `Cargo.lock`, `Gemfile.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`)
- Modifications to Claude Code's own configuration (`.claude/settings.json`, `.claude/settings.local.json`) and installed-hook directory (`.claude/hooks/`)

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
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
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
2. Extracts `tool_input.file_path`. NotebookEdit payloads carry the path as `tool_input.notebook_path` instead — the hook falls back to that field when `file_path` is absent.
3. Loads protected-path patterns from `rules.json` next to the hook (or built-in defaults if missing).
4. Compiles each pattern; skips invalid regexes silently rather than crashing.
5. Builds path variants from the raw tool path plus cwd/project-resolved relative paths.
6. Searches the variants against each pattern with `re.search`.
7. First pattern match → exit 2 with constructive stderr feedback.
8. No match → exit 0 (allow modification).

## Configuring rules.json

`rules.json` next to the hook script holds the pattern list:

```json
{
  "protected_patterns": [
    "(?:^|/)node_modules/",
    "(?:^|/)\\.git/",
    "(?:^|/)\\.env(?:\\.[^/]+)?$",
    "src/generated/"
  ]
}
```

- Patterns are Python regex (matched against full path with `re.search`)
- Escape `.` as `\\.` in JSON
- Order doesn't matter; first match wins
- Invalid regexes are silently skipped (the hook doesn't crash)

To add a pattern: edit `rules.json`. To temporarily disable one pattern: remove that pattern from the installed `rules.json` you actually use. To temporarily disable all hooks: set Claude Code's `disableAllHooks` in a local/project settings file, or uninstall the local meta-skills hook entries with `./install.sh <target> --uninstall`. Because this hook protects `.claude/settings*` and `.claude/hooks/`, make those changes from a shell or editor outside an active hook-blocked Claude Code tool call.

## Design decisions

- **Regex matching, not glob.** More expressive (lookahead, alternation, anchors). For users wanting glob-like simplicity, segment-aware patterns work: `(?:^|/)node_modules/`, `(?:^|/)src/generated/`.
- **`re.search` over path variants, not `re.fullmatch`.** The hook matches raw relative paths and cwd/project-resolved variants. When `CLAUDE_PROJECT_DIR` is present and the target is inside the project, it prefers the project-relative path so parent directories named like `node_modules` or `.env.project` do not false-positive.
- **Defaults include common cases for Node, Rust, Ruby, Python, Bun.** Project-specific paths should be added by the user.
- **Constructive feedback default.** Tells Claude what matched and how to override (ask user, modify rules.json). Punitive variant exists for A/B testing.
- **Exit code 2 + stderr** for blocking (per Claude Code hooks convention). JSON-based blocking via `permissionDecision: deny` is an alternative if exit 2 reliability issues surface (per GitHub issue #13744 — same risk as edit-drift-detector).
- **Invalid regex → skip pattern, don't crash.** Allows users to add custom patterns without risk of bricking the hook on syntax errors.

## Coexistence with other hooks

- This hook fires PreToolUse on `Write|Edit|MultiEdit|NotebookEdit`. If it blocks (exit 2), `silent-file-verifier`'s PostToolUse does NOT fire (correct — there's no modification to verify when it was prevented).
- Both `construction-gate` and `edit-drift-detector` match Edit. Claude Code may execute matching hooks in parallel, so protected-path privacy does not rely on hook order: construction-gate blocks with metadata-only feedback, and edit-drift self-skips protected paths before opening files.
- Independent of `completion-verifier` and `context-recovery` (different events).

Behavior documented per Claude Code lifecycle docs; not validated by the harness (which tests each hook in isolation).

## Known limitations

- **Plugin-path live proof covers Write/Edit/NotebookEdit, not MultiEdit.** A local `claude --plugin-dir .` smoke session proved this hook blocks protected `Write`, `Edit`, and `NotebookEdit` operations from the plugin scaffold. `MultiEdit` was not registered in that Claude Code session, so plugin-path `MultiEdit` remains covered by synthetic validation rather than live plugin dogfood.
- **GitHub issue #13744:** PreToolUse exit 2 has been reported as unreliable for blocking Write/Edit in some Claude Code versions. Same caveat as `edit-drift-detector`. If observed, switch to JSON-based blocking.
- **Path matching is regex, not git-aware.** A pattern like `\.git/` blocks all `.git` paths, including in nested git submodules and bare repos. Generally desirable.
- **No allowlist override.** If a user wants to write to a protected path intentionally (e.g., updating a lock file as part of a controlled refactor), they must temporarily disable the hook or modify `rules.json`. No "this one time only" mechanism.
- **Convergent with ecosystem.** Several tools cover similar ground (`danielmiessler/PAI` for path protection + TODO regex; native Claude Code permission deny rules; `claude-warden` for argument-aware path safety; `snagnever/claude-code-sidecar` for TOML-based policies). Our value is the validation suite + cross-language Python implementation, not the patterns.

## Performance

- Tracked harness average: 111ms/case in the current baseline snapshot, including Python startup and harness overhead.
- Path matching itself is microseconds for typical pattern lists (10-20 patterns).
- Pattern matching is O(N × M) where N is path length and M is number of patterns; for typical pattern lists (10-20 patterns) this is microseconds.
- Tracked timing snapshots live in `hooks/construction-gate/BASELINE-RESULTS.md`; local per-run JSON files in `validation/results/` are gitignored and regenerated.

## Testing

```bash
cd validation
./harness.sh construction-gate
```

32 test cases covering should-block (23) and should-pass (9), including protected-string boundary cases, cwd-relative protected paths, and false-positive guards for projects whose parent paths contain protected-looking segments. Tool coverage spans Write (most cases), Edit (`11-claude-settings`, `20-env-edit-mismatch`, `21-backslash-protected-path`, `22-relative-claude-settings-cwd`), MultiEdit (`18-claude-settings-local`), and NotebookEdit (`19-claude-hooks-dir`, exercising the `notebook_path` fallback). See `validation/test-cases/construction-gate/`.
