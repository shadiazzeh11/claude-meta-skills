# claude-meta-skills

Claude Code hooks with harness-measured false-positive and false-negative results.

Five focused hooks covering edit verification, completion gating, file checks, write protection, and pre-compaction recovery-state capture. Each ships with a test suite. The validation harness works for any Claude Code hook, not just ours.

| Hooks | Harness tests | Harness false positives | Harness false negatives | Crosley layers |
|---|---|---|---|---|
| 5 | 94 | 0 | 0 | 4/4 |

These headline numbers are harness-measured, not a production false-positive
rate. The public evidence narrative, caveats, and reproduction commands live in
[EVIDENCE.md](EVIDENCE.md).

## Fit

Install this if you use Claude Code on real repositories and want a small local reliability layer that targets common agent failure modes when the relevant lifecycle payload reaches the hooks: stale edit context, protected-file writes, ghost writes, failing tests at completion time, and lost context after compaction.

The project is strongest when you want:

- Project-local hooks that run from `.claude/settings.json` and stay with the repo.
- Deterministic checks with per-hook validation fixtures, CI, and baseline results.
- Local-only dogfood telemetry that can be summarized with `./testing/analyze-log.py --real-only`.
- A narrow verification layer that can coexist with broader workflow systems, command-safety tools, and observability dashboards.

Do not install it expecting:

- Bash command safety or sandboxing.
- A project-management workflow, TDD methodology, or subagent orchestration system.
- Persistent cross-project memory.
- A hosted dashboard or external telemetry.
- A public Claude plugin marketplace listing. This repo includes a Claude Code plugin scaffold, marketplace catalog, isolated marketplace CLI install regression, and marketplace-installed smoke evidence for four hooks, but public listing is still future work. See [PUBLISHING.md](PUBLISHING.md) for readiness notes.

## Install

```bash
git clone https://github.com/shadiazzeh11/claude-meta-skills.git
cd claude-meta-skills
./install.sh /path/to/your/project          # adds 5 hooks + settings.json
./install.sh /path/to/your/project --with-claude-md   # also installs CLAUDE.md template
./install.sh /path/to/your/project --uninstall         # removes local install entries/files
./doctor.sh /path/to/your/project           # read-only diagnostics for local install state
```

`install.sh` copies hooks to `.claude/hooks/meta-skills/` and creates or merges `.claude/settings.json` (preserves any hooks you already have). Re-running `install.sh` on the same project is idempotent: it replaces meta-skills hook entries instead of appending duplicates. Requires `jq` for merging into existing settings.

`doctor.sh` is read-only. It checks this source checkout, optional local install wiring under `.claude/`, copied-file drift from the current checkout, required tools, hook files, plugin manifests, and the local metadata log location without installing, uninstalling, invoking hooks, or printing raw log contents. You can also run `make doctor TARGET=/path/to/your/project`.

Security note: Claude Code command hooks run as local commands with your OS-user privileges. Review the source before installing. `completion-verifier` may run the target project's test command, `context-recovery` may modify project `CLAUDE.md` during compaction, and local metadata logs remain at `~/.claude/meta-skills-log.jsonl` until you delete them.

To remove the local install, run `./install.sh /path/to/your/project --uninstall` or `make uninstall TARGET=/path/to/your/project`. This removes only hook commands whose path contains `.claude/hooks/meta-skills/` and deletes `.claude/hooks/meta-skills/`; it preserves unrelated hooks, unrelated settings, and `CLAUDE.md`. If `.claude/settings.json` exists and cannot be parsed safely, uninstall stops before deleting hook files. For temporary broad disablement, set Claude Code's `disableAllHooks` setting in a local or project settings file. For plugin installs, use Claude Code's plugin marketplace tooling instead of `install.sh`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for pause, uninstall, plugin, and evidence-collection guidance.

For a disposable first-run protocol suitable for friends, reviewers, and
external testers, see [testing/NEW-USER-SMOKE.md](testing/NEW-USER-SMOKE.md).
Collect structured feedback with [testing/TESTER-FEEDBACK.md](testing/TESTER-FEEDBACK.md)
or the "New user smoke" GitHub issue form.

Manual alternative: copy `hooks/` into your project, then merge `templates/settings.json` into `.claude/settings.json`.

Experimental plugin path: the repo root includes `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and the standard `hooks/hooks.json` plugin hook file for Claude Code plugin validation and local marketplace installation tests. Marketplace-installed smoke evidence now covers construction-gate, silent-file-verifier, completion-verifier, and context-recovery. The local `install.sh` path above remains the recommended install path until public marketplace packaging is complete.

## Hooks

| Hook | Layer | Event | What it catches | Tests |
|---|---|---|---|---|
| [edit-drift-detector](hooks/edit-drift-detector/) | Prevention | `PreToolUse:Edit` | Fuzzy-match correction context for `old_string` drift on non-protected Edits that reach PreToolUse (Claude Code's built-in validation catches complete mismatches first — see hook README) | 14 |
| [construction-gate](hooks/construction-gate/) | Prevention | `PreToolUse:Write\|Edit\|MultiEdit\|NotebookEdit` | File modifications to protected paths (`node_modules/`, `.git/`, `.env*`, lock files, `.claude/` config and hooks) | 32 |
| [silent-file-verifier](hooks/silent-file-verifier/) | Validation | `PostToolUse:Write\|Edit\|MultiEdit\|NotebookEdit` | Ghost files (write reported success, file missing or 0 bytes) | 10 |
| [completion-verifier](hooks/completion-verifier/) | Quality Gating | `Stop` | Tests failing when Claude attempts to finish responding | 24 |
| [context-recovery](hooks/context-recovery/) | Context Injection | `PreCompact` | Session context lost during context-window compaction | 14 |

Each hook directory contains its own README with design decisions, known limitations, coexistence notes, and per-hook baseline results.

## How they work together

The five hooks cover Blake Crosley's four-layer hook framework (Prevention, Validation, Quality Gating, Context Injection) across five Claude Code lifecycle events. They fire in lifecycle order: `PreCompact` runs when context fills (recovering session state to CLAUDE.md), `PreToolUse` blocks bad Edits or Writes before they execute, `PostToolUse` warns on ghost files after Write/Edit/MultiEdit/NotebookEdit completes, and `Stop` blocks completion when tests are failing. Each hook fails open and can be installed independently. When installed as a suite, `construction-gate` is listed before `edit-drift-detector` for readability and stable generated settings, but protected-path privacy relies on `edit-drift-detector` self-skipping protected paths before it opens files because Claude Code may execute matching hooks in parallel.

```
Layer                Event                Hook
─────                ─────                ────
Context Injection    PreCompact      ──▶  context-recovery
Prevention           PreToolUse      ──▶  construction-gate
                     (Write|Edit|MultiEdit|NotebookEdit)
                     PreToolUse:Edit ──▶  edit-drift-detector
Validation           PostToolUse     ──▶  silent-file-verifier
                     (Write|Edit|MultiEdit|NotebookEdit)
Quality Gating       Stop            ──▶  completion-verifier
```

Command-safety (`PreToolUse:Bash`) is deliberately not covered. See [Related work and scope](#related-work-and-scope) for the alternatives we delegate to.

## Validation

Every hook ships with its own test suite. The counts below summarize the tracked per-hook baseline snapshots and current validation case inventory. They are **harness-measured** — each test case feeds an input payload directly to the hook's stdin, so the numbers reflect the hook's logic on constructed inputs, not in-session lifecycle reachability for every documented case (see each hook's README for real-session caveats — `edit-drift-detector` in particular notes that Claude Code's built-in Edit validation can intercept some payloads before PreToolUse hooks dispatch). The false-positive / false-negative columns are harness category counters for allow-vs-block expectations; stdout/stderr, file-content, privacy, and mutation assertions can still fail a case even when a hook's exit code is correct.

| Hook | Synthetic cases | Pass | False positives | False negatives |
|---|---|---|---|---|
| edit-drift-detector | 14 | 14 | 0 | 0 |
| construction-gate | 32 | 32 | 0 | 0 |
| silent-file-verifier | 10 | 10 | 0 | 0 |
| completion-verifier | 24 | 24 | 0 | 0 |
| context-recovery | 14 | 14 | 0 | 0 |
| **Total** | **94** | **94** | **0** | **0** |

Run the suite yourself:

```bash
cd validation
./harness.sh edit-drift-detector
# or all hooks at once:
make test
```

Per-hook baseline results, including timing snapshots, live in each hook directory's `BASELINE-RESULTS.md`. Per-run JSON output goes to `validation/results/` (gitignored, regenerated each run, not part of the release artifact).

GitHub Actions runs the plugin package regression, marketplace catalog regression, release metadata regression, validation harness lock regression, validation harness behavior regression, repository hygiene regression, doctor diagnostic regression, analyzer regression, installer lifecycle regression, `make test`, and `make test-stop-env` on every pull request and on every push to `main` across Ubuntu and macOS runners (see `.github/workflows/validation.yml`).

**The harness is generic.** It tests against assertions on exit code, stdout patterns, stderr patterns, file content, and file pattern counts — applicable to any Claude Code hook, not just ours. See [VALIDATION.md](VALIDATION.md) for how to validate your own hooks against the harness.

## Self-deployment data

Each hook auto-logs its fires to `~/.claude/meta-skills-log.jsonl` (one JSON line per block/warn/modify/skip event). Synthetic 94/94 constructed hook inputs pass in the harness; the auto-log is what tells you whether they're catching real issues during normal use.

```bash
./testing/analyze-log.py             # last 7 days summary
./testing/analyze-log.py --real-only # dogfood-only view (canonical for dogfood evidence)
./testing/analyze-log.py --days 30   # longer window
./testing/analyze-log.py --redact    # rewrite home prefix to ~ for safer sharing
./testing/analyze-log.py --format markdown --output dogfood-report.md
make report-dogfood                  # write ignored redacted Markdown/JSON reports under .context/reports/
```

Current dogfood evidence should be read from `./testing/analyze-log.py --real-only`, because the raw log can also contain manual proof and historical harness/validation entries. The analyzer includes an evidence scorecard and deterministic recommendations for missing live evidence, high-fire paths, context-recovery skip actions, non-real ratio, and log-integrity issues. The current dogfood baseline has real-session log evidence for all five hooks: `edit-drift-detector`, `construction-gate`, `silent-file-verifier`, `completion-verifier`, and `context-recovery`. After `v0.1.2`, a clean reset window produced 6 real fires across all five hooks in one disposable Claude Code session with `non_real_ratio=0.0%`; follow-up LOGOS real-project, transcript-shape, `v0.1.5`, marketplace-installed, long-session stress, LOGOS Phase C/Gamma-audit, and untracked-file smoke passes extended the active window to 29 real fires across 10 sessions and 8 projects. That window includes four stale-installed-hook `completion-verifier` false positives before `doctor.sh`/reinstall, post-reinstall intentional broken-state catches, `/compact` recovery proofs, a live transcript-shape proof after PR #47, `v0.1.5` self and marketplace smoke, a realistic ledger-feature stress session that exercised `construction-gate`, `silent-file-verifier`, `completion-verifier`, and `context-recovery` in one project, the LOGOS Gamma-audit failing-test checkpoint that exposed the untracked-file recovery gap, and a disposable untracked-file smoke that exposed copied-hook and settings-backup install noise. Treat this as lifecycle evidence that each hook has fired in live Claude Code sessions, not as proof of production false-positive rate or exhaustive real-world coverage. See [EVIDENCE.md](EVIDENCE.md), [testing/DOGFOOD-BASELINE.md](testing/DOGFOOD-BASELINE.md), and each hook README for caveats.

The plugin scaffold also has controlled local `claude --plugin-dir .` smoke evidence for `construction-gate`, `silent-file-verifier`, `completion-verifier`, and `context-recovery`. Marketplace-installed smoke evidence covers the same four hooks from an installed local marketplace plugin. `edit-drift-detector` still has non-plugin controlled live evidence plus synthetic validation, but not a separate plugin-path or marketplace-installed proof.

The `detail` field carries metadata only — paths, pattern names, line ranges, exit codes, similarity ratios. No file content, no diff snippets, no test output. Hooks create the log with private permissions (`~/.claude` 0700, log file 0600 on POSIX systems). See [testing/README.md](testing/README.md) for the full action enum, privacy boundaries, and what to look for after a week of dogfood usage.

## Configuration

Each hook is configurable without modifying its source code:

- **`rules.json`** (where applicable): Per-hook rule files for protected path patterns (`construction-gate`) and static reminders (`context-recovery`).
- **`messages.json`**: Per-hook feedback message templates with `constructive` (default) and `punitive` variants for A/B testing.
- **`templates/CLAUDE.md`**: Project-level CLAUDE.md template documenting installed hooks and verification discipline. Copy to your project root or use `install.sh --with-claude-md`.
- **`templates/settings.json`**: Complete hook configuration for all 5 hooks. Used by `install.sh`; can also be merged manually.

Each hook directory's README documents which files it reads and what fields they accept.

## Related work and scope

We focus on metacognitive verification — catching Claude's own mistakes during a session. Adjacent and overlapping projects in the ecosystem cover related ground:

- **Command safety** ([claude-warden](https://github.com/banyudu/claude-warden) for AST-based bash parsing, [Claude Code Auto Mode](https://www.anthropic.com/engineering/claude-code-auto-mode) for the built-in transcript classifier, [snagnever/sidecar](https://github.com/snagnever/claude-code-sidecar) for TOML-based policies). We don't ship a `PreToolUse:Bash` safety hook; these alternatives cover the space well.
- **Methodology and agent workflow** ([obra/superpowers](https://github.com/obra/superpowers) for TDD, planning, code-review skills). Different scope; complementary.
- **Persistent memory** ([Claude-Mem](https://docs.claude-mem.ai/) for cross-session memory with SQLite + vector search). Heavier than our PreCompact + CLAUDE.md approach; different problem class.
- **Language-specific code quality** ([omerkaz/claude-code-ts-quality-hook](https://github.com/omerkaz/claude-code-ts-quality-hook) for TypeScript lint/type checks; [danielmiessler/PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) for path protection plus TODO regex). We cover language-agnostic structural checks; these cover language-specific quality.
- **Observability dashboards** ([disler/claude-code-hooks-multi-agent-observability](https://github.com/disler/claude-code-hooks-multi-agent-observability) for real-time agent monitoring with WebSocket UI). Different category.
- **Marketplaces and directories** ([Claude Code Stack](https://www.claudecodestack.com/) and the [Claude plugin marketplace](https://claude.com/plugins)) help users discover hooks, skills, MCPs, agents, and plugins. Different distribution layer; this repo now has a plugin scaffold and local marketplace catalog, with public marketplace publication left for future work.

**Explicit non-goals:** command safety, agent workflow methodology, persistent cross-session memory, observability dashboards, and public marketplace publication. We focus on a small, validated, locally-installable hook suite.

For the current marketplace-readiness status, positioning, pre-publish checklist, changelog, and release runbook, see [PUBLISHING.md](PUBLISHING.md), [CHANGELOG.md](CHANGELOG.md), and [RELEASE.md](RELEASE.md).

## Known limitations

- **Cross-platform.** Hooks invoke `python3` directly. On Windows native (no WSL), `python3` may not be in PATH; use `python` or alias accordingly. Tested on macOS Darwin 25 and Linux. Windows native untested.
- **`SessionStart:compact` stdout injection has had documented failures** per [Claude Code Issue #15174](https://github.com/anthropics/claude-code/issues/15174), where the matcher fires but stdout is not injected into post-compaction context. Our `context-recovery` hook uses `PreCompact` + CLAUDE.md modification (the verified working path) instead.
- **`context-recovery` intentionally uses `PreCompact`, not `PostCompact`.** Current Claude Code docs list `PostCompact`, but the verified path for this repo is still `PreCompact` + CLAUDE.md modification so recovery state exists before compaction completes. Any future `PostCompact` or `SessionStart` redesign needs a fresh live-session proof of context delivery.
- **Async hook stdin bug on macOS** per [Claude Code Issue #38162](https://github.com/anthropics/claude-code/issues/38162) — `"async": true` causes empty stdin on macOS. All our hooks default to synchronous mode (the correct choice).
- **`construction-gate` is convergent with ecosystem.** Patterns are well-trodden ground (PAI's path protection, claude-warden's argument-aware rules, native Claude Code permission deny rules). Our value-add is the validation suite, not novel patterns.
- **Validation harness timing includes ~30-40 ms of Python startup overhead** per measurement. Real hook execution overhead when installed in Claude Code is approximately 30-45 ms lower than reported values.
- **Project type ambiguity in `completion-verifier`:** a repo with multiple project config files still uses the first supported config in priority order. Parent discovery now handles subdirectory Stop events, but mixed-language repos should still make their preferred test runner available through the highest-priority detected config.
- **Race condition window in `context-recovery`** when a user edits CLAUDE.md in another editor while the hook fires. Mitigated by atomic write (`tempfile.mkstemp` + `os.replace`); not eliminated.
- **CI is limited to GitHub Actions validation on Ubuntu and macOS;** there is no release/deploy pipeline yet. The workflow at `.github/workflows/validation.yml` runs plugin package validation, marketplace catalog validation, release metadata regression, validation harness lock regression, validation harness behavior regression, repository hygiene regression, doctor diagnostic regression, analyzer regression, installer lifecycle regression, `make test`, and `make test-stop-env` on every PR and every push to `main`. No release publication, no marketplace upload, no Windows runner, and no multi-Python matrix.
- **No public marketplace listing.** Install via `git clone` + `install.sh`. A plugin scaffold, marketplace catalog, isolated marketplace install regression, and marketplace-installed smoke evidence for four hooks exist, but public listing/release packaging is future work.

## License

MIT. See [LICENSE](LICENSE).

Joint copyright Shadi AL Azzeh and Caleb Mukasa, 2026.

Co-authored throughout by Claude Opus 4.7 (1M context).
