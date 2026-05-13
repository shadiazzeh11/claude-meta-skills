# Publishing readiness

This document is the product and marketplace readiness checklist for `claude-meta-skills`.

Current status: **v0.1.4 technical preview, local install recommended**. The repo has a tested installer/uninstaller, read-only doctor diagnostics, CI, controlled live-session dogfood evidence for all five hooks, local report export with an evidence scorecard, release checklist, tracked new-user smoke protocol, changelog, and a Claude Code plugin scaffold with local `--plugin-dir` smoke evidence. It also includes a marketplace catalog, isolated marketplace CLI regression, and marketplace-installed live smoke evidence for four hooks. It is not yet publicly listed in a marketplace; the local `install.sh` path remains the recommended path until public marketplace packaging is finished.

## Current distribution model

Today, users install from a git clone:

```bash
git clone https://github.com/shadiazzeh11/claude-meta-skills.git
cd claude-meta-skills
./install.sh /path/to/project
```

This copies hook files into the target project's `.claude/hooks/meta-skills/` directory and creates `.claude/settings.json`. When `jq` is available, it merges hook entries into an existing settings file; without `jq`, it prints manual merge instructions instead of modifying existing settings.

To remove a local install, users run:

```bash
./install.sh /path/to/project --uninstall
```

The uninstaller removes only hook commands whose path contains `.claude/hooks/meta-skills/`, deletes `.claude/hooks/meta-skills/`, and preserves unrelated hooks, unrelated settings, and `CLAUDE.md`. If `.claude/settings.json` exists and cannot be parsed safely, uninstall stops before deleting copied hook files. Plugin installs remain separate from this local installer path; Claude Code marketplace removal/uninstall is handled by Claude Code's plugin tooling.

This is a valid local distribution path for early users. It is not the same as marketplace distribution. Claude Code plugin docs distinguish standalone `.claude/` configuration from plugin packages; plugins add a `.claude-plugin/plugin.json` manifest and are the path for versioned team/community distribution and marketplace installation.

The repository now also includes an experimental plugin scaffold and local marketplace catalog:

- `.claude-plugin/plugin.json` declares the plugin metadata.
- `.claude-plugin/marketplace.json` declares a one-plugin marketplace catalog for `claude-meta-skills`.
- `hooks/hooks.json` uses the standard Claude Code plugin hook location and declares the same five hook entries using `${CLAUDE_PLUGIN_ROOT}` paths.
- `skills/verification-before-recommend/` is discovered as a bundled plugin skill when the repo is loaded as a plugin.

This scaffold is intended for validation and smoke testing. Local `claude --plugin-dir .` smoke tests have proved plugin-path hook loading for construction-gate, silent-file-verifier, completion-verifier, and context-recovery. `make test-marketplace` validates the marketplace manifest and, when `claude` is available locally, exercises `plugin marketplace add`, `plugin list --available`, `plugin install`, `plugin uninstall`, and `plugin marketplace remove` inside isolated temp config/cache directories. A disposable marketplace-installed smoke project has also proved construction-gate, silent-file-verifier, completion-verifier, and context-recovery from the installed plugin path. The `install.sh` path remains the recommended user install path until public marketplace packaging is complete.

Expected validation caveat: direct plugin-manifest validation with `claude plugin validate .claude-plugin/plugin.json` warns that the repo-root `CLAUDE.md` is not loaded as plugin context. That is acceptable for this scaffold; plugin-shipped context should live in `skills/`, and this repo already has `skills/verification-before-recommend/`. Running `claude plugin validate .` from this repo validates the marketplace manifest instead.

## Current evidence snapshot

| Area | Evidence |
|---|---|
| Synthetic validation | `make test` and `make test-stop-env` pass 93/93. |
| Installer lifecycle | `make test-installer` passes repeat-install, merge, uninstall, no-op uninstall, and preservation scenarios. |
| Doctor diagnostics | `make doctor TARGET=/path/to/project` performs read-only source/install diagnostics; `make test-doctor` covers source-only, no-`jq`, clean-target, installed, broken, duplicate, disabled, drifted-copy, missing-hook, and missing-target states. |
| CI | GitHub Actions runs plugin package checks, marketplace catalog checks, release metadata checks, validation harness lock checks, validation harness behavior checks, repository hygiene checks, doctor diagnostic checks, analyzer tests, installer tests, `make test`, and `make test-stop-env` on Ubuntu and macOS for PRs and pushes to `main`. |
| Live dogfood coverage | `./testing/analyze-log.py --real-only` shows controlled live-session evidence for all five hooks. The active post-`v0.1.2` window shows 13 real fires across 5 hooks, 4 sessions, and 3 projects, including the 6-fire clean disposable pass, four stale-installed-hook `completion-verifier` false positives before doctor/reinstall, one post-reinstall LOGOS broken-state catch, one LOGOS `context-recovery` proof, and one live transcript-shape `completion-verifier` proof after PR #47. |
| Plugin-path smoke | `claude --plugin-dir .` has controlled live-session evidence for construction-gate, silent-file-verifier, completion-verifier, and context-recovery. |
| Marketplace catalog | `.claude-plugin/marketplace.json` and `make test-marketplace` validate the local catalog and isolated CLI add/install/uninstall flow. Marketplace-installed live smoke has proved construction-gate, silent-file-verifier, completion-verifier, and context-recovery. |
| Report export | Analyzer can emit text, JSON, and Markdown reports. |
| Release docs | `CHANGELOG.md` and `RELEASE.md` define the technical-preview release scope and tag checklist. |
| New-user smoke | `testing/NEW-USER-SMOKE.md` defines a tag-pinned external tester protocol for local install, one controlled `completion-verifier` proof, recovery, uninstall, privacy expectations, and feedback collection. |
| Privacy boundary | Hook logs store metadata only; no file content, diffs, prompts, assistant responses, or test output. |

The baseline proves lifecycle reachability and observable behavior under controlled live Claude Code dogfood probes. It does not prove production false-positive rate, exhaustive real-world coverage, or organic frequency of each failure mode.

## Positioning

`claude-meta-skills` should be positioned as a narrow reliability layer, not a replacement for broader Claude Code ecosystems.

| Category | Examples | Relationship |
|---|---|---|
| Official Claude Code hooks | Claude Code hooks reference and hooks guide | This repo builds on the official lifecycle model: `PreToolUse`, `PostToolUse`, `Stop`, and `PreCompact`. |
| Workflow methodology | Superpowers | Complementary. Superpowers teaches structured development practices; this repo checks specific failure modes through hooks. |
| Hook collections | Community hook packs and directories | Smaller scope. The value here is measured validation, installer lifecycle tests, CI, dogfood classification, and explicit caveats. |
| Command safety | Claude Code Auto Mode, claude-warden, Sidecar-style policy tools | Out of scope. This repo does not ship a `PreToolUse:Bash` guard or sandbox. |
| Observability | Multi-agent observability dashboards | Complementary. This repo logs local hook fires and exports summaries, but does not run a server or dashboard. |
| Marketplaces | Claude plugin marketplace, plugin marketplaces, Claude Code Stack | Future distribution layer. The repo has a plugin scaffold, local catalog, isolated CLI install validation, and marketplace-installed smoke evidence, but it is not published as a marketplace plugin. |

## What not to claim

Do not claim:

- "Production proven."
- "Zero false positives in real use."
- "Complete Claude Code safety."
- "Published marketplace plugin."
- "Covers every way Claude can modify a protected file."
- "Replaces Superpowers, command-safety hooks, or observability tools."

Safe claims:

- "93/93 synthetic validation tests pass."
- "All five hooks have controlled live Claude Code session evidence."
- "The plugin scaffold has local `--plugin-dir` smoke evidence for four of five hooks; `edit-drift-detector` remains covered by non-plugin controlled dogfood and harness validation."
- "The marketplace catalog has isolated local CLI add/install/uninstall validation when Claude Code is available."
- "Marketplace-installed smoke evidence covers construction-gate, silent-file-verifier, completion-verifier, and context-recovery; edit-drift-detector remains covered by non-marketplace controlled dogfood and harness validation."
- "CI runs validation on pull requests and pushes to main."
- "Install and uninstall are project-local; install is idempotent and uninstall preserves unrelated hooks/settings."
- "Logs are local metadata only and can be redacted/exported."

## Pre-publish checklist

Before presenting this as a public marketplace/plugin-quality artifact or tagging another public release:

- Keep the plugin layout (`.claude-plugin/plugin.json`) valid.
- Bump `.claude-plugin/plugin.json` `version` for every public plugin release.
- Keep hook declarations in the standard plugin hook file (`hooks/hooks.json`) and ensure bundled hook commands use `${CLAUDE_PLUGIN_ROOT}`.
- Validate the plugin package with `make test-plugin` and `claude plugin validate .claude-plugin/plugin.json`.
- Keep `.claude-plugin/marketplace.json` valid with `make test-marketplace`.
- Keep explicit plugin versioning honest with `VERSION=vX.Y.Z make test-release`; Claude Code uses `plugin.json` `version` before marketplace entry versions or source commits.
- Keep local plugin loading smoke tests current with `claude --plugin-dir .` in disposable projects.
- Keep marketplace-installed live hook smoke tests current in disposable projects.
- Keep `testing/NEW-USER-SMOKE.md` current and run it with at least one external tester before public marketplace submission, or explicitly record environment blockers.
- Keep the marketplace-installed `edit-drift-detector` caveat unless a future Claude Code lifecycle exposes stale Edit payloads to PreToolUse before built-in `old_string` validation. The current evidence remains non-marketplace controlled live proof plus harness coverage.
- Keep the uninstall/disable guide current for local installs, plugin installs, and temporary hook disablement.
- Keep [TROUBLESHOOTING.md](TROUBLESHOOTING.md) current with Claude Code hook, settings, and plugin command changes before publishing.
- Keep `CHANGELOG.md` and `RELEASE.md` current, then add a release tag only after the release gate in `RELEASE.md` passes.
- Confirm the license, copyright owners, and co-author attribution remain correct.
- Keep GitHub Actions green on Ubuntu and macOS for `main`.
- Generate fresh dogfood reports:

```bash
make report-dogfood
```

- Review the docs and PR with Shadi and Caleb before publishing.
- Confirm macOS and Linux install smoke tests still pass.
- Decide whether Windows native support is out of scope or needs an explicit compatibility pass.

## Sources checked

Sources checked on 2026-05-09 and refreshed through 2026-05-12:

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugins reference: https://code.claude.com/docs/en/plugins-reference
- Claude Code plugin marketplace docs: https://code.claude.com/docs/en/plugin-marketplaces
- Claude Code discover/install plugin docs: https://code.claude.com/docs/en/discover-plugins
- Claude Code environment variables reference: https://code.claude.com/docs/en/env-vars
- Claude Code settings reference: https://code.claude.com/docs/en/settings
- Claude Code memory docs: https://code.claude.com/docs/en/memory
- Claude Code Auto Mode: https://www.anthropic.com/engineering/claude-code-auto-mode
- Official Superpowers plugin listing: https://claude.com/plugins/superpowers
- Superpowers skills repository: https://github.com/obra/superpowers-skills
- claude-warden command-safety hook: https://github.com/banyudu/claude-warden
- claude-code-sidecar command policy hook: https://github.com/snagnever/claude-code-sidecar
- GouvernAI runtime guardrails: https://github.com/Myr-Aya/GouvernAI-claude-code-plugin
- Community hook collection: https://github.com/karanb192/claude-code-hooks
- Multi-agent observability example: https://github.com/disler/claude-code-hooks-multi-agent-observability
- Claude Code Stack directory: https://www.claudecodestack.com/
- ClaudePluginHub directory: https://www.claudepluginhub.com/marketplaces
- Keep a Changelog: https://keepachangelog.com/en/1.0.0/
- Semantic Versioning 2.0.0: https://semver.org/

These sources informed the scope boundaries above: hooks lifecycle support is official; plugin/marketplace packaging is a distinct distribution step; broad workflow, command-safety, memory, and observability systems solve adjacent problems that this repo should not overclaim.
