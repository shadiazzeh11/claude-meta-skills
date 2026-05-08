# Baseline validation — construction-gate

Initial validation from Phase 3 build. Re-run via `cd validation && ./harness.sh construction-gate`.

| Metric | Value |
|---|---|
| Test date | 2026-05-08 (Phase 3) |
| Claude Code version | 2.1.128 |
| Python | 3.14.2 |
| OS | Darwin 25.3.0 |
| Test cases | 7 (3 should-block, 3 should-pass, 1 edge case) |
| Pass rate | 7 / 7 |
| False positives | 0 |
| False negatives | 0 |
| Avg duration / case | 49 ms |
| Min duration / case | 47 ms |
| Max duration / case | 58 ms |
| Total duration | 349 ms |

## Per-case results

| # | Case | Category | Exit | ms | Notes |
|---|---|---|---|---|---|
| 01 | node-modules | should-block | 2 | 58 | Write deep into node_modules path; matches `node_modules/` pattern |
| 02 | env-file | should-block | 2 | 49 | Write to .env.production; matches `\.env(?:\.\|$)` pattern |
| 03 | git-internals | should-block | 2 | 47 | Write deep into .git/objects/pack/; matches `\.git/` pattern; confirms regex matches anywhere in path |
| 04 | normal-path | should-pass | 0 | 47 | Write to src/app.py; no protected pattern matches |
| 05 | tmp-scratch | should-pass | 0 | 50 | Write to /tmp/scratch.txt; no protected pattern matches |
| 06 | filename-contains-protected-string | should-pass | 0 | 49 | Filename "my-node_modules-notes.md" contains "node_modules" substring but no `/` boundary; pattern correctly does NOT match (boundary test) |
| 07 | invalid-regex | should-block | 2 | 49 | rules.json contains an invalid regex; hook skips it gracefully and still enforces the valid `node_modules/` pattern; doesn't crash |

## Notes on performance

- All cases consistently 47-58ms. Hook is essentially Python startup + JSON parsing + regex compilation + path matching.
- **Timing caveat:** durations include ~30-40ms of Python startup overhead from the harness measurement method. Actual hook execution overhead when installed in Claude Code is approximately 30-45ms lower than reported values.

## Notes on observed behavior

- Constructive stderr message verified on all 4 should-block cases (3 normal blocks + invalid-regex test 07): contains pattern that matched and explanation.
- Boundary test (test 06) confirms `re.search` against `node_modules/` correctly distinguishes path boundary from filename substring.
- Invalid regex handling (test 07) confirms hook skips bad patterns rather than crashing — important for users adding custom patterns who might typo a regex.
- Default patterns include: `node_modules/`, `\.git/`, `\.env(?:\.\|$)`, lock files (npm/yarn/bun/pip/poetry/cargo/uv/ruby), `.claude/settings.json`. Per Phase 3 design, no TODO/placeholder check (delegated to ecosystem tools like danielmiessler/PAI).

## Phase 3 design choices

- **Narrow scope: protected paths only.** TODO/placeholder check dropped per Phase 3 plan — convergent with PAI's TODO regex implementation. Construction-gate's value is the path-protection layer + validation suite, not pattern reinvention.
- **Regex matching, not glob.** More expressive (lookahead, alternation, anchors). Test 06 verifies the boundary distinction.
- **Configurable via rules.json next to the hook.** Users can add project-specific patterns. Invalid patterns silently skipped.
- **Constructive feedback default.** Tells Claude what matched and how to override.

## Coexistence verified

When this hook coexists with `silent-file-verifier`:
- This hook fires PreToolUse on Write. If it blocks (exit 2), `silent-file-verifier`'s PostToolUse does NOT fire (correct — there's no Write to verify when prevented).
- Independent of `edit-drift-detector` (different matcher: Write vs Edit).

Per Claude Code lifecycle docs; not validated by harness (which tests hooks individually).

Per-run JSON written to `validation/results/construction-gate-<timestamp>.json` (gitignored).
