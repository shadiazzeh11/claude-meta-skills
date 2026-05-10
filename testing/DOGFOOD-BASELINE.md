# Dogfood baseline - 2026-05-09

This is the first complete live-session baseline after Phase 2B hardening.

The canonical command is:

```bash
./testing/analyze-log.py --real-only --redact
```

## Summary

As of the baseline snapshot:

| Hook | Real fires | Actions observed | Evidence shape |
|---|---:|---|---|
| `edit-drift-detector` | 1 | `block-fuzzy` | Controlled injected-drift `Edit` probe in a disposable project |
| `construction-gate` | 6 | `block` | Protected-path blocks across Write/Edit/MultiEdit/NotebookEdit smoke projects |
| `silent-file-verifier` | 2 | `warn-missing`, `warn-empty` | Fault-watcher induced missing-file and 0-byte Write anomalies |
| `completion-verifier` | 1 | `block` | Stop hook blocked completion after tests failed |
| `context-recovery` | 1 | `modify` | PreCompact hook wrote a Session Recovery block to CLAUDE.md |

Analyzer summary:

```text
Total: 11 fires across 5 hooks
Real Claude Code sessions: 6
Missing real-session evidence: (none)
```

## Interpretation

This baseline proves that each hook has fired from a live Claude Code session, reached its intended lifecycle event, emitted the expected action, and was classified by the analyzer as real dogfood.

It does not prove:

- Real-world false-positive rate.
- Real-world false-negative rate.
- Organic frequency of each failure mode.
- Exhaustive coverage of every hook branch in live sessions.

The synthetic validation suite remains the source for branch-level expected behavior. Dogfood evidence answers a different question: whether the hooks are actually reachable and observable in real Claude Code sessions.

## Caveats

`edit-drift-detector` evidence is controlled induced-drift evidence. Claude Code's built-in Edit validation intercepted the simplest "old_string not found" case before this hook produced feedback. To prove the live hook lifecycle, the disposable dogfood project used a local wrapper that changed `src/app.py` after Claude Code accepted the Edit payload and before invoking the real installed hook. That proves live payload handling and block behavior, not organic stale-edit frequency.

`silent-file-verifier` warning evidence is controlled anomaly evidence. A local fault watcher deleted one Write target and truncated another after Claude Code reported Write success. That proves the PostToolUse warning branches can fire in live sessions, not that ghost writes are common.

`context-recovery` evidence came from a manual `/compact` flow in a disposable project. The important signal is that the hook wrote the expected recovery block and the analyzer classified the log entry as real.

## External comparison

The project is not trying to beat broad workflow frameworks or hook collections by volume. It is trying to be a smaller reliability layer with testable claims.

- Official Claude Code hooks support the lifecycle model this repo relies on: matchers for tool events, `$CLAUDE_PROJECT_DIR` for project-local scripts, and exit-code blocking semantics for `PreToolUse`.
- Superpowers is a broad skills/plugin framework for methodology: brainstorming, TDD, debugging, subagent development, code review, and skill authoring. It is complementary; this repo focuses on metacognitive verification hooks and analyzer evidence.
- Community hook packs provide useful copy-paste hooks across many categories. This repo's narrower differentiation is measured validation, installer idempotency, CI, real-session dogfood classification, and per-hook caveats.
- Claude Code Stack and marketplace-style directories solve discovery. This repo still needs future packaging work before it should be presented as a polished marketplace artifact.

## Sources checked

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide
- Superpowers plugin listing: https://claude.com/plugins/superpowers
- Superpowers skills repository: https://github.com/obra/superpowers-skills
- Community hook collection: https://github.com/karanb192/claude-code-hooks
- Claude Code Stack directory: https://www.claudecodestack.com/
