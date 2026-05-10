# testing

Auto-logging and analysis for self-deployment validation. Each hook appends one JSON line to `~/.claude/meta-skills-log.jsonl` whenever it fires (blocks, warns, modifies, or skips). After a week of normal use, run `analyze-log.py` to see what's actually happening.

## What gets logged

One JSON line per fire. Schema:

```json
{
  "timestamp": "2026-05-08T22:30:42Z",
  "hook": "edit-drift-detector",
  "action": "block-fuzzy",
  "project": "/Users/shadi/code/flashquest",
  "detail": "file=src/auth.py lines=42-45 similarity=0.91",
  "session_id": "abcdef12-1234-1234-1234-1234567890ab"
}
```

| Field | Meaning |
|---|---|
| `timestamp` | ISO 8601 UTC, second precision |
| `hook` | hook name (one of the five) |
| `action` | what the hook did — see action enum below |
| `project` | `$CLAUDE_PROJECT_DIR` if set, else `cwd` from payload |
| `detail` | one-line metadata, capped at 200 chars |
| `session_id` | from the hook's stdin payload (groups fires within one Claude session) |

### Action enum

| Hook | Actions |
|---|---|
| `edit-drift-detector` | `block-fuzzy` (close match found, suggested correction), `block-no-match` (no similar content found) |
| `construction-gate` | `block` (matched a protected-path pattern) |
| `silent-file-verifier` | `warn-missing` (file not on disk after Write/Edit), `warn-empty` (Write of non-empty content produced 0-byte file) |
| `completion-verifier` | `block` (tests failed), `warn-timeout` (test command timed out), `warn-cmd-missing` (test runner not in PATH), `warn-cwd-missing` (cwd doesn't exist) |
| `context-recovery` | `modify` (replaced existing recovery section), `create` (no CLAUDE.md existed), `skip-readonly` (couldn't read existing CLAUDE.md), `skip-error` (atomic write failed) |

Hooks that allow silently (exit 0 with no output, no warning) do **not** log. We only record fires that actually did something — that's the signal worth analyzing.

## Privacy: what's NOT in the log

By design, the `detail` field carries **metadata only**:

- File paths and pattern names (path is identifying but not secret)
- Line ranges, similarity ratios, exit codes, byte counts, project type names
- Tool names (Write, Edit, MultiEdit, etc.)

The `detail` field never contains:

- File content, even snippets
- Diff fragments or `old_string`/`new_string` values
- Test output (stdout/stderr from the test command)
- Environment variable values, command arguments beyond the runner name
- User prompts or assistant responses

This is enforced by inspection and regression tests — each hook builds its own `detail` from a limited template, and the validation harness asserts sensitive strings stay out of stderr/log output for protected-path cases. If you ever want to share a log excerpt for a bug report or chat, the detail strings are safe in shape but paths still identify your projects. Use `--redact` (below) to swap your home prefix for `~`.

## Reading the log

```bash
./testing/analyze-log.py                  # summary, last 7 days
./testing/analyze-log.py --real-only      # dogfood-only view; canonical for dogfood evidence
./testing/analyze-log.py --days 30        # last N days
./testing/analyze-log.py --log /tmp/log.jsonl
./testing/analyze-log.py --redact         # rewrite /Users/<you>/ → ~/ for safer sharing
./testing/analyze-log.py --format markdown --output dogfood-report.md
./testing/analyze-log.py --format json --output dogfood-report.json
./testing/analyze-log.py --help
```

Sample output:

```
Hook fire summary (last 7 days):

  completion-verifier: 7 fires (5 block, 1 warn-timeout, 1 warn-cmd-missing)
  construction-gate: 4 fires (4 block)
  context-recovery: 8 fires (5 modify, 2 create, 1 skip-error)
  edit-drift-detector: 6 fires (3 block-fuzzy, 3 block-no-match)
  silent-file-verifier: 3 fires (2 warn-missing, 1 warn-empty)

Total: 28 fires across 5 hooks

Classification totals (all matching log entries, before --real-only display filter):
  real dogfood: 28 fires
  manual/synthetic: 0 fires
  harness/validation: 0 fires
  unknown: 0 fires
  Real Claude Code sessions: 4

Real dogfood hook coverage:
  Observed real hooks: edit-drift-detector (6), construction-gate (4), silent-file-verifier (3), completion-verifier (7), context-recovery (8)
  Missing real-session evidence: (none)

Real dogfood sessions:
  abcdef12… — 9 fires, 4 hooks (completion-verifier, construction-gate, context-recovery, edit-drift-detector), project=/Users/shadi/code/flashquest, time=2026-05-08T22:30:42Z..2026-05-08T23:15:10Z

Top triggered files:
  src/auth.py — 4 fires (edit-drift-detector)
  ...

Projects:
  /Users/shadi/code/flashquest — 15 fires
  ...
```

`analyze-log.py` classifies each entry into one of four buckets so validation runs do not pollute dogfood interpretation:

| Bucket | What it means |
|---|---|
| `real dogfood` | UUID-shaped `session_id` from a live Claude Code session, project path outside `validation/test-cases/`. |
| `manual/synthetic` | `session_id` is a manual marker (e.g. `manual-test`), used when piping payloads to a hook by hand. |
| `harness/validation` | `session_id="test-session"` or project/file path under `validation/test-cases/` — typically produced by `make test` or `./validation/harness.sh`. |
| `unknown` | Doesn't match any of the above. |

Use `--real-only` when reporting dogfood evidence. Default output intentionally includes all buckets and prints classification totals so you can spot harness or manual noise at a glance. The raw JSONL is still useful when you need to inspect a specific session or correlate timestamps across mixed runs.

The analyzer also prints a real dogfood hook coverage section. This is the fastest way to see which hooks have been proven in live Claude Code sessions and which still only have synthetic or harness evidence. If historical harness entries dominate the active log, the default view prints a noise note and points you back to `--real-only`.

Raw JSONL is at `~/.claude/meta-skills-log.jsonl` if you want to grep, jq, or feed into a different analyzer.

The current complete dogfood evidence snapshot is documented in [DOGFOOD-BASELINE.md](DOGFOOD-BASELINE.md). Keep that file narrow: it records live-session evidence and caveats, while this README documents the analyzer and log format.

## Report export

`analyze-log.py` can render the same summary in three formats:

| Format | Use |
|---|---|
| `text` | Default terminal output; stable for quick local inspection. |
| `markdown` | Shareable dogfood reports for PRs, reviews, and weekly summaries. |
| `json` | Structured output for downstream scripts, dashboards, or archived measurements. |

Examples:

```bash
./testing/analyze-log.py --real-only --redact --format markdown --output dogfood-report.md
./testing/analyze-log.py --real-only --redact --format json --output dogfood-report.json
```

`--output` writes only the selected report file and does not print the report to stdout. When `--redact` is enabled, emitted path and project fields are redacted in text, markdown, and JSON. The JSON report includes displayed hook totals, all-bucket classification totals, real-session coverage, top files, top projects, parse errors, and timestamp errors.

## What to look for after a week of usage

Three signal categories, in order of priority:

1. **Hooks that never fire.** A hook with zero fires across a week of real coding is either (a) catching a problem that doesn't actually happen for you, or (b) silently broken. Check the hook's known-limitations to decide. If a hook is genuinely not earning its keep for your workflow, disable it in `.claude/settings.json`.

   Start with the analyzer's `Missing real-session evidence` line from `--real-only`. Missing does not automatically mean broken — for example, `silent-file-verifier` only logs anomaly paths — but it tells you which hooks still need dogfood coverage or a deliberate decision.

2. **High-fire-rate files.** A file showing up in the top-files list with many fires from the same hook is a friction signal. Examples:
   - Same file fires `edit-drift-detector` 5+ times in a week → either you're memorizing it wrong systematically, or the hook's similarity threshold is too tight for that file's structure (consider why; don't just disable).
   - Same `.env*` path firing `construction-gate` repeatedly → you're trying to write env files that the gate is correctly blocking. Consider whether you actually need to disable that pattern for that project.

3. **`skip-*` actions on `context-recovery`.** Any `skip-readonly` or `skip-error` means compaction happened but the recovery section didn't write — a silent failure. If these accumulate, investigate filesystem permissions on your CLAUDE.md.

What the log can't tell you:

- **Did Claude actually self-correct after the hook fired?** The log records the fire but not the next-turn outcome. That's qualitative — you have to remember whether the block-fuzzy on `auth.py` led to a clean retry or whether Claude got confused. Keep notes during the week if you want this signal.
- **False positive rate in real use.** A `block-fuzzy` that suggested wrong content, or a `warn-missing` for a file that was about to materialize, are FPs but not visible in the log alone. Cross-reference with your memory of the session.

## Harness log isolation

`make test` and `./validation/harness.sh` run each hook with `HOME` pointed at a per-run temp directory. Hook fires from validation still use `session_id="test-session"` and still appear in the harness's captured stdout/stderr/results, but their auto-log writes go to the temp home and are removed when the harness exits. The active dogfood log at `~/.claude/meta-skills-log.jsonl` stays dogfood-only during normal validation runs.

`analyze-log.py --real-only` still filters historical harness entries from older runs and remains the canonical dogfood evidence view.

## Log file management

- **Append-only.** No rotation, no automatic cleanup. At ~200 chars per line and ~30 fires/day (heavy usage), the file grows ~22 KB/day = ~8 MB/year. Not a real concern unless you're heavily multi-project and multi-decade.
- **Private permissions.** Hooks create `~/.claude` with mode `0700` and `meta-skills-log.jsonl` with mode `0600` where the platform supports POSIX permissions. Existing permissive log files are tightened best-effort on the next hook fire.
- **Manual reset.** `> ~/.claude/meta-skills-log.jsonl` truncates without removing the file. Useful if you want to start a fresh measurement window.
- **No telemetry leaves your machine.** Local-only by design. The log file never gets uploaded anywhere by these hooks. If you want to share findings, paste analyze-log output (with `--redact`) — not the raw JSONL.

## Why log fires and not allows

Logging every PreToolUse:Edit (most of which the hook allows silently) would balloon the file fast — Claude makes hundreds of edits per active hour. The signal we care about is "the hook caught something" — that's what tells us whether each hook earns its keep. If you ever need fire-rate-as-fraction-of-attempts, that requires correlating with a separate count of total tool calls, which the JSONL session transcript already provides.
