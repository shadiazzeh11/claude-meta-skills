# claude-meta-skills

Meta-cognitive skills for Claude Code. Verification discipline shipped; postmortem and other agent-improvement work in progress.

## Status

In active development. Full methodology documentation, post-probe findings, and skill iteration history coming in subsequent commits.

## Current artifacts

- `CLAUDE.md` — global verification protocol, loads at every session start
- `skills/verification-before-recommend/SKILL.md` — auto-triggered discipline skill, validated 6/6 via variance probes (2026-05-01)
- `HARNESS-BUG.md` — Claude Code 2.1.126 plan-mode trigger on user-space Skill tool invocations (reproducible, undocumented)

## License

MIT
