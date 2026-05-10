# Dogfood baseline - 2026-05-09

This is the first complete live-session baseline after Phase 2B hardening, extended with plugin-path smoke evidence after the Claude Code plugin scaffold landed.

The canonical command is:

```bash
./testing/analyze-log.py --real-only --redact
```

## Summary

As of the baseline snapshot:

| Hook | Real fires | Actions observed | Evidence shape |
|---|---:|---|---|
| `edit-drift-detector` | 1 | `block-fuzzy` | Controlled injected-drift `Edit` probe in a disposable project |
| `construction-gate` | 9 | `block` | Protected-path blocks across live Write/Edit/NotebookEdit smoke projects; synthetic validation covers MultiEdit |
| `silent-file-verifier` | 4 | `warn-missing`, `warn-empty` | Fault-watcher induced missing-file and 0-byte Write anomalies, including plugin-path proof |
| `completion-verifier` | 3 | `block` | Stop hook blocked completion after tests failed, including plugin-path proof |
| `context-recovery` | 2 | `modify` | PreCompact hook wrote a Session Recovery block to CLAUDE.md, including plugin-path `/compact` proof |

Analyzer summary:

```text
Total: 19 fires across 5 hooks
Real Claude Code sessions: 8
Missing real-session evidence: (none)
```

## Interpretation

This baseline proves that each hook has fired from a live Claude Code session, reached its intended lifecycle event, emitted the expected action, and was classified by the analyzer as real dogfood.

The plugin-path extension proves the scaffold can load hooks through `claude --plugin-dir /path/to/claude-meta-skills` and produce real hook interventions for:

- `construction-gate`: `Write`, `Edit`, and `NotebookEdit` protected-path blocks.
- `silent-file-verifier`: `warn-missing` and `warn-empty`.
- `completion-verifier`: failing-test `Stop` block. The plugin smoke recorded two Stop blocks because the project stayed intentionally broken for a follow-up watcher-stop turn.
- `context-recovery`: manual `/compact` produced a Session Recovery block via `PreCompact`.

It does not prove:

- Real-world false-positive rate.
- Real-world false-negative rate.
- Organic frequency of each failure mode.
- Exhaustive coverage of every hook branch in live sessions.
- Marketplace installation behavior.

The synthetic validation suite remains the source for branch-level expected behavior. Dogfood evidence answers a different question: whether the hooks are actually reachable and observable in real Claude Code sessions.

## Caveats

`edit-drift-detector` evidence is controlled induced-drift evidence. Claude Code's built-in Edit validation intercepted the simplest "old_string not found" case before this hook produced feedback. To prove the live hook lifecycle, the disposable dogfood project used a local wrapper that changed `src/app.py` after Claude Code accepted the Edit payload and before invoking the real installed hook. That proves live payload handling and block behavior, not organic stale-edit frequency.

`silent-file-verifier` warning evidence is controlled anomaly evidence. A local fault watcher deleted one Write target and truncated another after Claude Code reported Write success. That proves the PostToolUse warning branches can fire in live sessions, not that ghost writes are common.

`context-recovery` evidence came from a manual `/compact` flow in a disposable project. The important signal is that the hook wrote the expected recovery block and the analyzer classified the log entry as real.

Plugin-path `construction-gate` evidence did not include a live `MultiEdit` invocation because `MultiEdit` was not registered in that Claude Code session. `MultiEdit` remains covered by the synthetic validation harness; the plugin-path live proof covers `Write`, `Edit`, and `NotebookEdit`.

Plugin-path sessions:

- `83c42ff4...`: 7 fires from `claude --plugin-dir .` smoke (`construction-gate` 3, `silent-file-verifier` 2, `completion-verifier` 2).
- `68ef1eab...`: 1 fire from `claude --plugin-dir .` manual `/compact` smoke (`context-recovery` 1).

Plugin-path evidence does not yet include `edit-drift-detector`. The existing `edit-drift-detector` real-session evidence remains the controlled injected-drift proof described above.

## External comparison

The project is not trying to beat broad workflow frameworks or hook collections by volume. It is trying to be a smaller reliability layer with testable claims.

- Official Claude Code hooks support the lifecycle model this repo relies on: matchers for tool events, `$CLAUDE_PROJECT_DIR` for project-local scripts, plugin `hooks/hooks.json`, `${CLAUDE_PLUGIN_ROOT}` for plugin-bundled scripts, and exit-code blocking semantics for `PreToolUse`.
- Superpowers is a broad skills/plugin framework for methodology: brainstorming, TDD, debugging, subagent development, code review, and skill authoring. It is complementary; this repo focuses on metacognitive verification hooks and analyzer evidence.
- Community hook packs provide useful copy-paste hooks across many categories. This repo's narrower differentiation is measured validation, installer idempotency, CI, real-session dogfood classification, and per-hook caveats.
- Claude Code Stack and marketplace-style directories solve discovery. This repo still needs future packaging work before it should be presented as a polished marketplace artifact.

## Sources checked

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugins reference: https://code.claude.com/docs/en/plugins-reference
- Superpowers plugin listing: https://claude.com/plugins/superpowers
- Superpowers skills repository: https://github.com/obra/superpowers-skills
- Community hook collection: https://github.com/karanb192/claude-code-hooks
- Claude Code Stack directory: https://www.claudecodestack.com/
