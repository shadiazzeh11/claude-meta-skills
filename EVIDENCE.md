# Evidence brief

`claude-meta-skills` is a small Claude Code reliability layer: five local hooks
that make Claude verify itself at the points where agent sessions commonly go
wrong. It is not a general agent framework, a shell sandbox, or a telemetry
service.

## One-line claim

The project adds a local, validated verification loop around Claude Code:
protect risky writes, check edits against real file state, verify written files
exist, block completion when tests are red, and preserve recovery context before
compaction.

## The five-step verification loop

| Step | Lifecycle point | Hook | What it verifies |
|---|---|---|---|
| 1 | `PreCompact` | `context-recovery` | Before context compaction, write a bounded recovery block to `CLAUDE.md` with branch, recent commits, tracked/untracked in-progress files, reminders, and custom compact instructions. |
| 2 | `PreToolUse` | `construction-gate` | Before writes execute, block protected paths such as `.env*`, `.git/`, `node_modules/`, lock files, and Claude settings/hooks. |
| 3 | `PreToolUse:Edit` | `edit-drift-detector` | Before an edit executes, compare Claude's proposed `old_string` with current file contents so stale or fuzzy edit context can be caught. |
| 4 | `PostToolUse` | `silent-file-verifier` | After write-like tools report success, check that the target file actually exists and is not unexpectedly empty. |
| 5 | `Stop` | `completion-verifier` | When Claude tries to finish, run the detected project test command and block completion if tests fail. |

Those hooks map onto the four reliability layers used in the project docs:
context injection, prevention, validation, and quality gating.

## Validation stack

The current tracked validation evidence is layered so one kind of test does not
pretend to prove everything:

| Layer | Current evidence | What it proves |
|---|---|---|
| Synthetic harness | `make test` and `make test-stop-env` pass `94/94` cases. | Hook logic handles constructed payloads, expected block/allow/warn behavior, privacy assertions, file effects, and edge cases. |
| CI | GitHub Actions runs the full validation stack on Ubuntu and macOS for PRs and pushes to `main`. | The suite is repeatable off the maintainer's machine on two OS runners. |
| Installer/doctor | `make test-installer` and `make test-doctor` pass. | Local install, idempotent reinstall, uninstall, drift detection, and diagnostics work in controlled scenarios. |
| Plugin packaging | `make test-plugin`, `make test-marketplace`, and `make test-release VERSION=v0.1.5` pass. | Plugin metadata, hook command mapping, local marketplace catalog, and release metadata are internally consistent. |
| Live dogfood | `./testing/analyze-log.py --real-only --redact` reports `29` real fires across all five hooks, `10` sessions, and `8` projects. | The hooks have fired in real Claude Code lifecycle sessions and produced the expected actions. |

The evidence does **not** prove production false-positive rate, exhaustive
real-world coverage, Windows native support, or safety for arbitrary shell
commands.

## Dogfood findings that changed the product

The useful signal is not just that hooks fired; several tests found real gaps
that were fixed.

| Finding | Evidence source | Result |
|---|---|---|
| Stale installed hook produced false-positive `completion-verifier` behavior in LOGOS. | LOGOS dogfood sessions and `doctor.sh` comparison. | Reinstall/doctor flow became part of the operational playbook. |
| `completion-verifier` transcript scanner needed hardening for live Claude Code transcript shapes. | Live transcript-shape smoke. | Scanner now recognizes nested `tool_use` / `tool_call` / `tool_calls` shapes. |
| `context-recovery` originally missed untracked new files after compaction. | LOGOS Gamma-audit stress session. | Recovery block now includes tracked changes plus untracked non-ignored files. |
| Copied `.claude/hooks/meta-skills/` files could swamp the recovery list and hide the real note. | Disposable untracked-file smoke. | Recovery list filters copied hook-install artifacts. |
| Timestamped `.claude/settings.json.backup-*` files were still install noise. | Follow-up untracked-file smoke plus read-only review. | Recovery list filters settings backup files, including collision suffixes. |
| External smoke instructions could create a broken baseline if pasted text introduced `U+00A0` spaces. | Caleb new-user smoke. | New-user runbook now generates files with a safer script and tells testers to stop if baseline tests are red. |

## Current dogfood snapshot

Canonical command:

```bash
./testing/analyze-log.py --real-only --redact
```

Current real-only window:

```text
completion-verifier: 12 fires
construction-gate: 3 fires
context-recovery: 9 fires
edit-drift-detector: 1 fire
silent-file-verifier: 4 fires

Total: 29 fires across 5 hooks
status=complete; hooks=5/5 real; real_sessions=10; real_projects=8
```

Read this as lifecycle evidence, not production-rate evidence. It says every
hook has reached its intended Claude Code lifecycle point in controlled live
sessions.

## Privacy and telemetry posture

The project is local-first by design.

- Logs stay on the user's machine at `~/.claude/meta-skills-log.jsonl`.
- The repo does not send hook data to GitHub, the maintainers, a server, or a
  database.
- Logs are metadata-only: hook name, action, timestamps, project path, target
  path, pattern names, line ranges, exit codes, similarity ratios, and session
  IDs.
- Logs should not contain prompts, assistant responses, source contents, diffs,
  `old_string` / `new_string`, secrets, or full test output.

Users and testers share evidence voluntarily by running redacted analyzer output.

## Public positioning

Strong positioning:

- "A small local verification layer for Claude Code hooks."
- "Validated hook suite with harness tests, CI, installer diagnostics, and live
  dogfood evidence."
- "Complements workflow systems like Superpowers, command-safety tools, and
  observability dashboards."

Avoid claiming:

- "Production proven."
- "Zero real-world false positives."
- "Complete Claude Code safety."
- "Bash sandboxing."
- "Public marketplace listing" until Anthropic approval is actually complete.

## Reproduce the current evidence locally

```bash
make test
make test-stop-env
make test-plugin
make test-marketplace
make test-release VERSION=v0.1.5
make test-doctor
make test-installer
make test-analyzer
./testing/analyze-log.py --real-only --redact
```

For a first-time external tester, use `testing/NEW-USER-SMOKE.md` and collect
feedback with `testing/TESTER-FEEDBACK.md`.
