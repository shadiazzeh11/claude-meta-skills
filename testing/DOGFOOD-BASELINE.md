# Dogfood baseline - 2026-05-11

This is the complete live-session baseline after Phase 2B hardening and the clean post-`v0.1.2` dogfood window.

The canonical command is:

```bash
./testing/analyze-log.py --real-only --redact
```

## Latest clean window after v0.1.2

After tagging `v0.1.2`, the active hook log was archived and reset before a fresh disposable Claude Code dogfood pass. That clean window produced:

```text
Total: 6 fires across 5 hooks
Evidence scorecard: status=complete; hooks=5/5 real; real_fires=6; real_sessions=1; real_projects=1; non_real_ratio=0.0%
Missing real-session evidence: (none)
```

| Hook | Real fires | Actions observed | Evidence shape |
|---|---:|---|---|
| `edit-drift-detector` | 1 | `block-fuzzy` | Controlled induced-drift `Edit` probe using the disposable project's local `install.sh` hook copy, restored afterward |
| `construction-gate` | 1 | `block` | Protected `package-lock.json` Write blocked in the disposable project |
| `silent-file-verifier` | 2 | `warn-missing`, `warn-empty` | Fault-watcher induced missing-file and 0-byte Write anomalies |
| `completion-verifier` | 1 | `block` | Stop hook blocked completion after an intentional failing test |
| `context-recovery` | 1 | `modify` | Manual `/compact` wrote a Session Recovery block to `CLAUDE.md` |

The clean-window project was `/tmp/claude-meta-v012-dogfood-1.X6bEWJ`, session `577ea11f...`, spanning `2026-05-11T05:38:38Z..2026-05-11T06:00:40Z`. Redacted Markdown and JSON reports were generated under `.context/reports/` and are intentionally ignored local evidence artifacts.

The `edit-drift-detector` entry is a controlled lifecycle proof, not an organic stale-Edit proof, plugin-path proof, or marketplace-installed proof. Claude Code's built-in Edit validation still catches common stale `old_string` failures before this hook can respond. The controlled wrapper mutated the disposable probe file after Claude Code accepted a valid Edit payload and before invoking the preserved original local project hook copy, causing the real hook to emit its `block-fuzzy` feedback and log entry.

## Historical release snapshot before v0.1.2

The broader release baseline below was collected before the clean post-`v0.1.2` log reset. It remains useful as historical evidence across plugin-path, marketplace-installed, and earlier disposable-project smoke sessions, but the canonical command against the current active log now reports the 6-fire clean window above unless the archived release log is restored.

As of that release baseline snapshot:

| Hook | Real fires | Actions observed | Evidence shape |
|---|---:|---|---|
| `edit-drift-detector` | 1 | `block-fuzzy` | Controlled injected-drift `Edit` probe in a disposable project |
| `construction-gate` | 12 | `block` | Protected-path blocks across live Write/Edit/NotebookEdit smoke projects, including fresh plugin-path and marketplace-installed release smoke; synthetic validation covers MultiEdit |
| `silent-file-verifier` | 6 | `warn-missing`, `warn-empty` | Fault-watcher induced missing-file and 0-byte Write anomalies, including plugin-path and marketplace-installed proof |
| `completion-verifier` | 7 | `block` | Stop hook blocked completion after tests failed, including fresh plugin-path and marketplace-installed release smoke |
| `context-recovery` | 5 | `modify` | PreCompact hook wrote a Session Recovery block to CLAUDE.md, including fresh plugin-path and marketplace-installed `/compact` proof |

Analyzer summary:

```text
Total: 31 fires across 5 hooks
Real Claude Code sessions: 11
Missing real-session evidence: (none)
```

## Interpretation

This baseline proves that each hook has fired from a live Claude Code session, reached its intended lifecycle event, emitted the expected action, and was classified by the analyzer as real dogfood.

The plugin-path extension proves the scaffold can load hooks through `claude --plugin-dir /path/to/claude-meta-skills` and produce real hook interventions for:

- `construction-gate`: `Write`, `Edit`, and `NotebookEdit` protected-path blocks.
- `silent-file-verifier`: `warn-missing` and `warn-empty`.
- `completion-verifier`: failing-test `Stop` block. The plugin smoke recorded two Stop blocks because the project stayed intentionally broken for a follow-up watcher-stop turn.
- `context-recovery`: manual `/compact` produced a Session Recovery block via `PreCompact`.
- Release refresh session `b9338ede...`: plugin-path smoke proved `construction-gate`, `completion-verifier`, and `context-recovery` from `claude --plugin-dir /Users/shadi/conductor/repos/claude-meta-skills`; `silent-file-verifier` was exercised on the valid non-empty Write path and correctly stayed silent.

The marketplace-installed extension proves the local marketplace catalog can install the plugin into a disposable project and produce real hook interventions from the installed plugin path for:

- `construction-gate`: `Write` block on `package-lock.json` from the installed plugin.
- `silent-file-verifier`: `warn-missing` and `warn-empty` after a fault watcher removed/truncated Write targets.
- `completion-verifier`: failing-test `Stop` block after an intentional `src/app.py` regression.
- `context-recovery`: manual `/compact` produced a Session Recovery block via `PreCompact`, preserving `DOGFOOD_MARKETPLACE_INSTALL_SENTINEL=marketplace-install-001`.
- Release refresh session `e7ea0f39...`: isolated marketplace-installed smoke proved `construction-gate`, `completion-verifier`, and `context-recovery` from the installed plugin path; `silent-file-verifier` was exercised on the valid non-empty Write path and correctly stayed silent.

It does not prove:

- Real-world false-positive rate.
- Real-world false-negative rate.
- Organic frequency of each failure mode.
- Exhaustive coverage of every hook branch in live sessions.
- Public marketplace listing behavior.

The synthetic validation suite remains the source for branch-level expected behavior. Dogfood evidence answers a different question: whether the hooks are actually reachable and observable in real Claude Code sessions.

## Caveats

`edit-drift-detector` evidence is controlled induced-drift evidence. Claude Code's built-in Edit validation intercepted the simplest "old_string not found" case before this hook produced feedback. To prove the live hook lifecycle, the disposable dogfood project used a local wrapper that changed `src/app.py` after Claude Code accepted the Edit payload and before invoking the real installed hook. That proves live payload handling and block behavior, not organic stale-edit frequency.

`silent-file-verifier` warning evidence is controlled anomaly evidence. A local fault watcher deleted one Write target and truncated another after Claude Code reported Write success. That proves the PostToolUse warning branches can fire in live sessions, not that ghost writes are common.

`context-recovery` evidence came from a manual `/compact` flow in a disposable project. The important signal is that the hook wrote the expected recovery block and the analyzer classified the log entry as real.

Plugin-path `construction-gate` evidence did not include a live `MultiEdit` invocation because `MultiEdit` was not registered in that Claude Code session. `MultiEdit` remains covered by the synthetic validation harness; the plugin-path live proof covers `Write`, `Edit`, and `NotebookEdit`.

Plugin-path sessions:

- `83c42ff4...`: 7 fires from `claude --plugin-dir .` smoke (`construction-gate` 3, `silent-file-verifier` 2, `completion-verifier` 2).
- `68ef1eab...`: 1 fire from `claude --plugin-dir .` manual `/compact` smoke (`context-recovery` 1).
- `b9338ede...`: 4 fires from release `claude --plugin-dir /Users/shadi/conductor/repos/claude-meta-skills` smoke (`construction-gate` 1, `completion-verifier` 2, `context-recovery` 1).

Marketplace-installed sessions:

- `66c19904...`: 5 fires from local marketplace install smoke (`construction-gate` 1, `silent-file-verifier` 2, `completion-verifier` 1, `context-recovery` 1).
- `e7ea0f39...`: 3 fires from release isolated marketplace-installed smoke (`construction-gate` 1, `completion-verifier` 1, `context-recovery` 1).

Plugin-path and marketplace-installed evidence do not yet include `edit-drift-detector`. The existing `edit-drift-detector` real-session evidence remains the controlled injected-drift proof described above.

A `v0.1.2` marketplace-installed edit-drift smoke attempt confirmed the same Claude Code lifecycle caveat in the installed-plugin path: after a required `Read`, an `Edit` with a stale `old_string` failed with Claude Code's built-in `String to replace not found in file` error before any PreToolUse hook response or log entry. This did not change the real-only baseline counts, and the release claims intentionally keep the marketplace-installed edit-drift caveat.

## External comparison

The project is not trying to beat broad workflow frameworks or hook collections by volume. It is trying to be a smaller reliability layer with testable claims.

- Official Claude Code hooks support the lifecycle model this repo relies on: matchers for tool events, `$CLAUDE_PROJECT_DIR` for project-local scripts, plugin `hooks/hooks.json`, `${CLAUDE_PLUGIN_ROOT}` for plugin-bundled scripts, and exit-code blocking semantics for `PreToolUse`.
- Superpowers is a broad skills/plugin framework for methodology: brainstorming, TDD, debugging, subagent development, code review, and skill authoring. It is complementary; this repo focuses on metacognitive verification hooks and analyzer evidence.
- Community hook packs provide useful copy-paste hooks across many categories. This repo's narrower differentiation is measured validation, installer lifecycle tests, CI, real-session dogfood classification, and per-hook caveats.
- Claude Code Stack and marketplace-style directories solve discovery. This repo still needs future packaging work before it should be presented as a polished marketplace artifact.

## Sources checked

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugins reference: https://code.claude.com/docs/en/plugins-reference
- Claude Code plugin marketplace docs: https://code.claude.com/docs/en/plugin-marketplaces
- Claude Code discover/install plugin docs: https://code.claude.com/docs/en/discover-plugins
- Claude Code environment variables reference: https://code.claude.com/docs/en/env-vars
- Superpowers plugin listing: https://claude.com/plugins/superpowers
- Superpowers skills repository: https://github.com/obra/superpowers-skills
- Community hook collection: https://github.com/karanb192/claude-code-hooks
- Claude Code Stack directory: https://www.claudecodestack.com/
