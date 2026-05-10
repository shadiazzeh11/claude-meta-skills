# Publishing readiness

This document is the product and marketplace readiness checklist for `claude-meta-skills`.

Current status: **technical preview, local install recommended**. The repo has a tested installer, CI, controlled live-session dogfood evidence for all five hooks, local report export, and a Claude Code plugin scaffold. It is not yet listed in a marketplace, and the plugin install path still needs dedicated smoke testing before it replaces `install.sh` as the recommended path.

## Current distribution model

Today, users install from a git clone:

```bash
git clone https://github.com/shadiazzeh11/claude-meta-skills.git
cd claude-meta-skills
./install.sh /path/to/project
```

This copies hook files into the target project's `.claude/hooks/meta-skills/` directory and creates `.claude/settings.json`. When `jq` is available, it merges hook entries into an existing settings file; without `jq`, it prints manual merge instructions instead of modifying existing settings.

This is a valid local distribution path for early users. It is not the same as marketplace distribution. Claude Code plugin docs distinguish standalone `.claude/` configuration from plugin packages; plugins add a `.claude-plugin/plugin.json` manifest and are the path for versioned team/community distribution and marketplace installation.

The repository now also includes an experimental plugin scaffold:

- `.claude-plugin/plugin.json` declares the plugin metadata.
- `hooks/hooks.json` declares the same five hook entries using `${CLAUDE_PLUGIN_ROOT}` paths.
- `skills/verification-before-recommend/` is discovered as a bundled plugin skill when the repo is loaded as a plugin.

This scaffold is intended for validation and smoke testing. The `install.sh` path remains the recommended user install path until plugin install tests are documented and passing.

Expected validation caveat: `claude plugin validate .` warns that the repo-root `CLAUDE.md` is not loaded as plugin context. That is acceptable for this scaffold; plugin-shipped context should live in `skills/`, and this repo already has `skills/verification-before-recommend/`.

## Evidence snapshot

As of the first complete dogfood baseline:

| Area | Evidence |
|---|---|
| Synthetic validation | `make test` and `make test-stop-env` pass 61/61. |
| Installer idempotency | `make test-installer` passes repeat-install and merge scenarios. |
| CI | GitHub Actions runs plugin package checks, analyzer tests, installer tests, `make test`, and `make test-stop-env` on PRs and pushes to `main`. |
| Live dogfood coverage | `./testing/analyze-log.py --real-only` shows controlled live-session evidence for all five hooks. |
| Report export | Analyzer can emit text, JSON, and Markdown reports. |
| Privacy boundary | Hook logs store metadata only; no file content, diffs, prompts, assistant responses, or test output. |

The baseline proves lifecycle reachability and observable behavior under controlled live Claude Code dogfood probes. It does not prove production false-positive rate, exhaustive real-world coverage, or organic frequency of each failure mode.

## Positioning

`claude-meta-skills` should be positioned as a narrow reliability layer, not a replacement for broader Claude Code ecosystems.

| Category | Examples | Relationship |
|---|---|---|
| Official Claude Code hooks | Claude Code hooks reference and hooks guide | This repo builds on the official lifecycle model: `PreToolUse`, `PostToolUse`, `Stop`, and `PreCompact`. |
| Workflow methodology | Superpowers | Complementary. Superpowers teaches structured development practices; this repo checks specific failure modes through hooks. |
| Hook collections | Community hook packs and directories | Smaller scope. The value here is measured validation, installer idempotency, CI, dogfood classification, and explicit caveats. |
| Command safety | Claude Code Auto Mode, claude-warden, Sidecar-style policy tools | Out of scope. This repo does not ship a `PreToolUse:Bash` guard or sandbox. |
| Observability | Multi-agent observability dashboards | Complementary. This repo logs local hook fires and exports summaries, but does not run a server or dashboard. |
| Marketplaces | Claude plugin marketplace, plugin marketplaces, Claude Code Stack | Future distribution layer. The repo has a plugin scaffold, but it is not published as a marketplace plugin. |

## What not to claim

Do not claim:

- "Production proven."
- "Zero false positives in real use."
- "Complete Claude Code safety."
- "Marketplace-ready plugin."
- "Covers every way Claude can modify a protected file."
- "Replaces Superpowers, command-safety hooks, or observability tools."

Safe claims:

- "61/61 synthetic validation tests pass."
- "All five hooks have controlled live Claude Code session evidence."
- "CI runs validation on pull requests and pushes to main."
- "Install is idempotent and project-local."
- "Logs are local metadata only and can be redacted/exported."

## Pre-publish checklist

Before presenting this as a public marketplace/plugin-quality artifact:

- Keep the plugin layout (`.claude-plugin/plugin.json`) valid.
- Bump `.claude-plugin/plugin.json` `version` for every public plugin release.
- Keep hook declarations in plugin format (`hooks/hooks.json`) and ensure bundled hook commands use `${CLAUDE_PLUGIN_ROOT}`.
- Validate the plugin package with `make test-plugin` and `claude plugin validate .`.
- Test local plugin loading with `claude --plugin-dir .` in a disposable project.
- Test marketplace installation locally with `/plugin marketplace add` and `/plugin install` once a marketplace manifest exists.
- Add an uninstall or disable guide for removing meta-skills hook entries from `.claude/settings.json`.
- Add a release tag and changelog entry for the first public release.
- Confirm the license, copyright owners, and co-author attribution remain correct.
- Keep GitHub Actions green on `main`.
- Generate fresh dogfood reports:

```bash
./testing/analyze-log.py --real-only --redact --format markdown --output .context/reports/dogfood-report.md
./testing/analyze-log.py --real-only --redact --format json --output .context/reports/dogfood-report.json
```

- Review the docs and PR with Shadi and Caleb before publishing.
- Confirm macOS and Linux install smoke tests still pass.
- Decide whether Windows native support is out of scope or needs an explicit compatibility pass.

## Sources checked

Sources checked on 2026-05-09:

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugins reference: https://code.claude.com/docs/en/plugins-reference
- Claude Code plugin marketplace docs: https://code.claude.com/docs/en/plugin-marketplaces
- Claude Code Auto Mode: https://www.anthropic.com/engineering/claude-code-auto-mode
- Official Superpowers plugin listing: https://claude.com/plugins/superpowers
- Superpowers skills repository: https://github.com/obra/superpowers-skills
- claude-warden command-safety hook: https://github.com/banyudu/claude-warden
- claude-code-sidecar command policy hook: https://github.com/snagnever/claude-code-sidecar
- Community hook collection: https://github.com/karanb192/claude-code-hooks
- Multi-agent observability example: https://github.com/disler/claude-code-hooks-multi-agent-observability
- Claude Code Stack directory: https://www.claudecodestack.com/

These sources informed the scope boundaries above: hooks lifecycle support is official; plugin/marketplace packaging is a distinct distribution step; broad workflow, command-safety, memory, and observability systems solve adjacent problems that this repo should not overclaim.
