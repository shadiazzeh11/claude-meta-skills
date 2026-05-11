# Baseline validation — construction-gate

Re-run via `cd validation && ./harness.sh construction-gate`.

| Metric | Value |
|---|---|
| Test date | 2026-05-10 (privacy hardening update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 21 (18 should-block, 3 should-pass, including one boundary edge case) |
| Pass rate | 21 / 21 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 122 ms |
| Min duration / case | 77 ms |
| Max duration / case | 415 ms |
| Total duration | 2578 ms |

## Per-case results

| # | Case | Category | Tool | Exit | ms | Notes |
|---|---|---|---|---|---|---|
| 01 | node-modules | should-block | Write | 2 | 99 | Write deep into node_modules path; matches `node_modules/` pattern |
| 02 | env-file | should-block | Write | 2 | 83 | Write to .env.production; matches `\.env(?:\.\|$)` pattern |
| 03 | git-internals | should-block | Write | 2 | 78 | Write deep into .git/objects/pack/; matches `\.git/` pattern; confirms regex matches anywhere in path |
| 04 | normal-path | should-pass | Write | 0 | 84 | Write to src/app.py; no protected pattern matches |
| 05 | tmp-scratch | should-pass | Write | 0 | 162 | Write to /tmp/scratch.txt; no protected pattern matches |
| 06 | filename-contains-protected-string | should-pass | Write | 0 | 180 | Filename "my-node_modules-notes.md" contains "node_modules" substring but no `/` boundary; pattern correctly does NOT match (boundary test) |
| 07 | invalid-regex | should-block | Write | 2 | 188 | Hook skips invalid regexes gracefully and still enforces the valid `node_modules/` pattern; doesn't crash |
| 08 | package-lock | should-block | Write | 2 | 195 | Write to package-lock.json; matches `package-lock\.json$` pattern |
| 09 | yarn-lock | should-block | Write | 2 | 158 | Write to yarn.lock; matches `yarn\.lock$` pattern |
| 10 | bun-lockb | should-block | Write | 2 | 415 | Write to bun.lockb; matches `bun\.lockb$` pattern |
| 11 | claude-settings | should-block | Edit | 2 | 109 | Edit on .claude/settings.json — exercises Edit tool with file_path; matches `\.claude/settings\.json$` pattern |
| 12 | cargo-lock | should-block | Write | 2 | 85 | Write to Cargo.lock; matches `Cargo\.lock$` pattern |
| 13 | gemfile-lock | should-block | Write | 2 | 84 | Write to Gemfile.lock; matches `Gemfile\.lock$` pattern |
| 14 | poetry-lock | should-block | Write | 2 | 79 | Write to poetry.lock; matches `poetry\.lock$` pattern |
| 15 | uv-lock | should-block | Write | 2 | 80 | Write to uv.lock; matches `uv\.lock$` pattern |
| 16 | pnpm-lock | should-block | Write | 2 | 85 | Write to pnpm-lock.yaml; matches `pnpm-lock\.yaml$` pattern (Phase 2B.3) |
| 17 | pipfile-lock | should-block | Write | 2 | 84 | Write to Pipfile.lock; matches `Pipfile\.lock$` pattern (Phase 2B.3) |
| 18 | claude-settings-local | should-block | MultiEdit | 2 | 77 | MultiEdit on .claude/settings.local.json — exercises MultiEdit tool with file_path; matches `\.claude/settings\.local\.json$` pattern (Phase 2B.3) |
| 19 | claude-hooks-dir | should-block | NotebookEdit | 2 | 86 | NotebookEdit payload uses `notebook_path` fallback (no `file_path` provided); matches `\.claude/hooks/` pattern (Phase 2B.3) |
| 20 | env-edit-mismatch | should-block | Edit | 2 | 84 | Edit payload against `.env.local` is blocked without echoing secret-bearing `old_string` / `new_string` values |
| 21 | backslash-protected-path | should-block | Edit | 2 | 83 | Windows-style backslash path normalizes before protected-pattern matching; blocks without echoing secret-bearing strings |

## Notes on performance

- Most cases complete under 200ms. Hook is essentially Python startup + JSON parsing + regex compilation + path matching; occasional local runner spikes are reflected in the table.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Constructive stderr message verified on all should-block cases: contains the matched pattern and explanation.
- Boundary test (case 06) confirms `re.search` against `node_modules/` correctly distinguishes path boundary from filename substring.
- Invalid-regex handling (case 07) confirms hook skips bad patterns rather than crashing — important for users adding custom patterns who might typo a regex.
- Tool coverage: cases 01–10/12–17 use `Write`, cases 11/20/21 use `Edit`, case 18 uses `MultiEdit`, case 19 uses `NotebookEdit` (exercising the `tool_input.notebook_path` fallback when `file_path` is absent).
- Default patterns include: `node_modules/`, `\.git/`, `\.env(?:\.|$)`, lock files (npm/yarn/bun/pnpm/pip/Pipfile/poetry/cargo/uv/ruby), `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks/`. Per Phase 3 design, no TODO/placeholder check (delegated to ecosystem tools like danielmiessler/PAI).

## Phase 2B.3 changes

- **Matcher widened from `Write` to `Write|Edit|MultiEdit|NotebookEdit`** so protected-path enforcement covers every file-modifying tool, not just Write.
- **`notebook_path` fallback added** so NotebookEdit payloads (which carry the path under `tool_input.notebook_path` instead of `tool_input.file_path`) are matched.
- **Four new protected patterns added:** `pnpm-lock\.yaml$`, `Pipfile\.lock$`, `\.claude/settings\.local\.json$`, `\.claude/hooks/`.
- **`DEFAULT_PATTERNS` resynced with `rules.json`** so hook fallback (when `rules.json` is missing) protects the same surface as the configured rules.
- **Permanent installer-idempotency assertion** that the installed construction-gate hook entry uses matcher `Write|Edit|MultiEdit|NotebookEdit`.
- **Privacy ordering assertion** added to installer/plugin regressions so construction-gate precedes edit-drift-detector in PreToolUse. Protected Edit payloads block before any fuzzy content feedback hook can inspect the file.

## Phase 3 design choices (still in effect)

- **Narrow scope: protected paths only.** TODO/placeholder check dropped per Phase 3 plan — convergent with PAI's TODO regex implementation. Construction-gate's value is the path-protection layer + validation suite, not pattern reinvention.
- **Regex matching, not glob.** More expressive (lookahead, alternation, anchors). Case 06 verifies the boundary distinction.
- **Configurable via rules.json next to the hook.** Users can add project-specific patterns. Invalid patterns silently skipped.
- **Constructive feedback default.** Tells Claude what matched and how to override.

## Coexistence verified

When this hook coexists with the rest of the meta-skills suite:
- This hook fires PreToolUse on `Write|Edit|MultiEdit|NotebookEdit`. If it blocks (exit 2), `silent-file-verifier`'s PostToolUse does NOT fire (correct — there's no modification to verify when prevented).
- Both `construction-gate` and `edit-drift-detector` fire on `Edit`. In the shipped configuration, construction-gate runs first; protected paths block with metadata-only feedback before edit-drift can inspect file content. edit-drift also self-skips protected paths as defense in depth.

Per Claude Code lifecycle docs; not validated by harness (which tests hooks individually).

Per-run JSON written to `validation/results/construction-gate-<timestamp>.json` (gitignored).
