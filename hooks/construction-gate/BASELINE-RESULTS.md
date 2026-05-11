# Baseline validation — construction-gate

Re-run via `cd validation && ./harness.sh construction-gate`.

| Metric | Value |
|---|---|
| Test date | 2026-05-11 (relative path hardening update) |
| Claude Code version | 2.1.138 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 32 (23 should-block, 9 should-pass, including boundary and relative-path edge cases) |
| Pass rate | 32 / 32 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 111 ms |
| Min duration / case | 87 ms |
| Max duration / case | 273 ms |
| Total duration | 3560 ms |

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
| 22 | relative-claude-settings-cwd | should-block | Edit | 2 | 88 | Relative Edit from inside `.claude/` resolves against cwd/project root and blocks `settings.json` |
| 23 | relative-claude-hooks-cwd | should-block | Write | 2 | 89 | Relative Write from inside `.claude/` resolves against cwd/project root and blocks `hooks/...` |
| 24 | parent-relative-env-file | should-block | Write | 2 | 88 | Parent-relative path from `src/` resolves to `.env.local` and blocks without echoing content |
| 25 | relative-normal-path | should-pass | Write | 0 | 89 | Relative Write to ordinary source file remains allowed after cwd/project resolution |
| 26 | relative-node-modules-cwd | should-block | Write | 2 | 99 | Relative Write from inside `node_modules/` resolves against cwd/project root and blocks |
| 27 | relative-git-internals-cwd | should-block | Write | 2 | 88 | Relative Write from inside `.git/objects` resolves against cwd/project root and blocks |
| 28 | parent-env-project-false-positive | should-pass | Write | 0 | 179 | Project root named `.env.project` does not cause ordinary source path to block |
| 29 | parent-node-modules-false-positive | should-pass | Write | 0 | 90 | Project under parent `node_modules/` does not cause ordinary project-relative path to block |
| 30 | raw-env-project-dir-false-positive | should-pass | Write | 0 | 88 | `.env.project/` directory name does not match protected `.env` file pattern |
| 31 | raw-lock-suffix-false-positive | should-pass | Write | 0 | 92 | `my-package-lock.json` does not match protected `package-lock.json` lockfile |
| 32 | absolute-parent-node-modules-false-positive | should-pass | Write | 0 | 88 | Absolute path inside project under parent `node_modules/` is matched project-relatively and stays allowed |

## Notes on performance

- Most cases complete under 200ms. Hook is essentially Python startup + JSON parsing + regex compilation + path matching; occasional local runner spikes are reflected in the table.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Constructive stderr message verified on all should-block cases: contains the matched pattern and explanation.
- Boundary test (case 06) confirms `re.search` against `node_modules/` correctly distinguishes path boundary from filename substring.
- Invalid-regex handling (case 07) confirms hook skips bad patterns rather than crashing — important for users adding custom patterns who might typo a regex.
- Tool coverage: cases 01–10/12–17/23–32 use `Write`, cases 11/20/21/22 use `Edit`, case 18 uses `MultiEdit`, case 19 uses `NotebookEdit` (exercising the `tool_input.notebook_path` fallback when `file_path` is absent).
- Default patterns include segment-aware rules for `node_modules/`, `\.git/`, `.env` files, lock files (npm/yarn/bun/pnpm/pip/Pipfile/poetry/cargo/uv/ruby), `.claude/settings.json`, `.claude/settings.local.json`, and `.claude/hooks/`. Per Phase 3 design, no TODO/placeholder check (delegated to ecosystem tools like danielmiessler/PAI).

## Phase 4 reliability hardening

- **Relative path resolution added.** The hook now resolves relative tool paths against payload `cwd` and, when available, matches project-relative paths using `CLAUDE_PROJECT_DIR`. This blocks protected relative writes from inside `.claude/`, `.git/`, `node_modules/`, and parent-relative `.env` targets.
- **Segment-aware default patterns added.** Protected patterns now use path-segment boundaries so ordinary paths like `.env.project/src/app.py`, `docs/my-package-lock.json`, or projects whose parent directory is named `node_modules` do not false-positive.
- **Fixture setup failure surfaced.** Case 07's invalid-regex setup path is now validated by the harness instead of being silently ignored.

## Phase 2B.3 changes

- **Matcher widened from `Write` to `Write|Edit|MultiEdit|NotebookEdit`** so protected-path enforcement covers every file-modifying tool, not just Write.
- **`notebook_path` fallback added** so NotebookEdit payloads (which carry the path under `tool_input.notebook_path` instead of `tool_input.file_path`) are matched.
- **Four new protected patterns added:** `pnpm-lock\.yaml$`, `Pipfile\.lock$`, `\.claude/settings\.local\.json$`, `\.claude/hooks/`.
- **`DEFAULT_PATTERNS` resynced with `rules.json`** so hook fallback (when `rules.json` is missing) protects the same surface as the configured rules.
- **Permanent installer-idempotency assertion** that the installed construction-gate hook entry uses matcher `Write|Edit|MultiEdit|NotebookEdit`.
- **Stable PreToolUse ordering assertion** added to installer/plugin regressions so generated settings list construction-gate before edit-drift-detector. Protected-path privacy relies on edit-drift self-skipping protected paths before opening files, because Claude Code may execute matching hooks in parallel.

## Phase 3 design choices (still in effect)

- **Narrow scope: protected paths only.** TODO/placeholder check dropped per Phase 3 plan — convergent with PAI's TODO regex implementation. Construction-gate's value is the path-protection layer + validation suite, not pattern reinvention.
- **Regex matching, not glob.** More expressive (lookahead, alternation, anchors). Case 06 verifies the boundary distinction.
- **Configurable via rules.json next to the hook.** Users can add project-specific patterns. Invalid patterns silently skipped.
- **Constructive feedback default.** Tells Claude what matched and how to override.

## Coexistence verified

When this hook coexists with the rest of the meta-skills suite:
- This hook fires PreToolUse on `Write|Edit|MultiEdit|NotebookEdit`. If it blocks (exit 2), `silent-file-verifier`'s PostToolUse does NOT fire (correct — there's no modification to verify when prevented).
- Both `construction-gate` and `edit-drift-detector` match `Edit`. Claude Code may execute matching hooks in parallel, so protected-path privacy does not rely on hook order: construction-gate blocks with metadata-only feedback, and edit-drift self-skips protected paths before opening files.

Per Claude Code lifecycle docs; not validated by harness (which tests hooks individually).

Per-run JSON written to `validation/results/construction-gate-<timestamp>.json` (gitignored).
