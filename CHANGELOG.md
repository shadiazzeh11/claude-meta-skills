# Changelog

All notable changes to `claude-meta-skills` are documented here.

This project uses a Keep a Changelog-style structure and version numbers intended to follow Semantic Versioning once public release guarantees are established.

## [Unreleased]

### Fixed

- Hardened `context-recovery` project-root discovery when `$CLAUDE_PROJECT_DIR` is absent: subdirectory compactions now write to the nearest parent `CLAUDE.md` or git root instead of creating recovery blocks in the nested cwd.

## [0.1.3] - 2026-05-11

### Added

- Documented the clean post-`v0.1.2` dogfood window: 6 real fires across all five hooks in one disposable Claude Code session with `non_real_ratio=0.0%`.
- Documented the LOGOS real-project dogfood extension: four stale-installed-hook `completion-verifier` false positives before `doctor.sh`/reinstall, then a post-reinstall intentional broken-state catch in a `uv` project plus `context-recovery` `/compact` proof.
- Added construction-gate validation cases for cwd-relative protected paths and false-positive guards around protected-looking parent directories.
- Added completion-verifier validation cases for invalid, zero, and negative timeout environment values.
- Added validation harness behavior and repository hygiene regression targets.
- Added read-only `doctor.sh` / `make doctor` diagnostics plus `make test-doctor` regression coverage for source and local-install health checks, including copied-file drift detection.

### Fixed

- Resolved cwd-relative protected-path matching in construction-gate while avoiding false positives from project parent paths named like protected directories.
- Hardened `COMPLETION_VERIFIER_TIMEOUT_SECS` parsing so malformed or non-positive values fall back to the default timeout.
- Made validation harness setup failures fail the owning case instead of being silently swallowed.
- Changed `make clean` to preserve the tracked `validation/results/.gitkeep` placeholder.

## [0.1.2] - 2026-05-11

### Added

- Added `make report-dogfood` for generating ignored redacted Markdown and JSON dogfood evidence reports.
- Added `TROUBLESHOOTING.md` for pausing, uninstalling, debugging, and reporting hook behavior across local and plugin installs.
- Added `make test-release VERSION=vX.Y.Z` to validate release metadata and plugin version alignment before tagging.
- Added validation harness locking plus `make test-validation-lock` to prevent concurrent fixture mutation races.

### Changed

- Corrected plugin package validation guidance and regression coverage to validate `.claude-plugin/plugin.json` explicitly instead of relying on repo-root validation.
- Added the release metadata regression to GitHub Actions validation.
- Added the validation harness lock regression to GitHub Actions validation.
- Expanded GitHub Actions validation from Ubuntu-only to an Ubuntu + macOS runner matrix.
- Clarified that protected-path privacy relies on edit-drift self-skipping protected paths, not on hook execution order.

## [0.1.1] - 2026-05-11

### Added

- Added an analyzer evidence scorecard and deterministic recommendations so dogfood reports show real hook coverage, real session/project counts, non-real ratio, and next actions.

### Changed

- Clarified post-`v0.1.0` release and publishing documentation so it reads as a reusable release process rather than only a first-release checklist.
- Simplified README validation summary by removing stale duration figures from the public table; tracked per-hook baseline files remain the source for timing snapshots.
- Aligned per-hook README performance notes and baseline category summaries with current tracked validation fixtures.
- Marked the historical external review package as archived/stale more prominently.

### Fixed

- Fixed a stale validation harness example path in `VALIDATION.md`.
- Clarified that `validation/results/` files are local regenerated outputs, not tracked release artifacts.

## [0.1.0] - 2026-05-11

### Added

- Five Claude Code hooks:
  - `edit-drift-detector` for stale `old_string` edit context.
  - `construction-gate` for protected-path file modifications.
  - `silent-file-verifier` for missing or unexpectedly empty file-write results.
  - `completion-verifier` for failing tests at `Stop`.
  - `context-recovery` for pre-compaction recovery-state capture in `CLAUDE.md`.
- Generic validation harness with fixture-based assertions for exit code, stdout/stderr patterns, file content, and file pattern counts.
- Aggregate `make test` target and per-hook `make test-<hook>` targets.
- `make test-stop-env` regression for validating under a simulated Claude Code Stop-hook environment.
- GitHub Actions validation workflow on pull requests and pushes to `main`.
- Local installer for project `.claude/settings.json` hook configuration.
- Idempotent installer merge behavior that preserves unrelated hooks and settings.
- Safe local uninstall path:
  - `install.sh --uninstall`
  - `make uninstall TARGET=<path>`
  - preserves unrelated hooks/settings and `CLAUDE.md`
  - aborts before deleting hook files when settings cleanup is unsafe
- Installer lifecycle regression suite covering repeat install, duplicate normalization, uninstall, no-op uninstall, invalid JSON, missing `jq`, mixed hook arrays, and space-containing target paths.
- Auto-logging to `~/.claude/meta-skills-log.jsonl` with local metadata only.
- Analyzer for hook-fire summaries:
  - real dogfood classification
  - synthetic/manual/harness filtering
  - redaction
  - text, JSON, and Markdown exports
- Controlled real Claude Code dogfood evidence for all five hooks.
- `testing/DOGFOOD-BASELINE.md` with real-session evidence, caveats, and ecosystem comparison.
- Claude Code plugin scaffold:
  - `.claude-plugin/plugin.json`
  - `hooks/hooks.json`
  - bundled `skills/verification-before-recommend/`
- Plugin package validation:
  - `make test-plugin`
  - `testing/test-plugin-package.sh`
  - `claude plugin validate .claude-plugin/plugin.json` when Claude Code is available
- Local marketplace catalog:
  - `.claude-plugin/marketplace.json`
  - `make test-marketplace`
  - isolated marketplace add/list/install/uninstall/remove regression
- Plugin-path smoke evidence for construction-gate, silent-file-verifier, completion-verifier, and context-recovery.
- Marketplace-installed smoke evidence for construction-gate, silent-file-verifier, completion-verifier, and context-recovery.
- Publishing readiness guide with positioning, safe claims, non-goals, and pre-publish checklist.
- Privacy hardening for protected paths, including metadata-only construction-gate blocking and edit-drift self-skipping before file-content inspection.
- Documentation for known Claude Code lifecycle caveats and relevant upstream issues.

### Changed

- Expanded construction-gate from `Write` coverage to `Write|Edit|MultiEdit|NotebookEdit`.
- Expanded construction-gate protected patterns to include more lock files and `.claude/` settings/hooks paths.
- Ordered construction-gate before edit-drift-detector in installed `PreToolUse` configuration for stable generated settings.
- Updated installer and CI language from narrow idempotency wording to installer lifecycle coverage.
- Updated README validation counts to `67/67`.
- Reworked dogfood reporting guidance around `./testing/analyze-log.py --real-only`.
- Clarified that public marketplace listing is future work and local `install.sh` remains the recommended install path.
- Clarified that `context-recovery` intentionally uses `PreCompact` plus `CLAUDE.md` modification rather than relying on post-compaction context injection.

### Fixed

- Isolated validation harness runs from inherited `CLAUDE_PROJECT_DIR`.
- Isolated validation harness logs from the active dogfood log by running hooks under per-run temp `HOME`.
- Resolved relative hook payload paths against payload `cwd`.
- Preserved unrelated hook entries when installer merges settings repeatedly.
- Preserved unrelated commands inside mixed hook arrays during install and uninstall.
- Prevented duplicated meta-skills hook entries after repeated installs.
- Prevented unsafe uninstall from deleting copied hook files when settings cleanup cannot run safely.
- Fixed `make install` and `make uninstall` wrappers for `TARGET` paths containing spaces.
- Avoided duplicate hook loading when both plugin and project-local hook configuration are present.
- Made completion-verifier `cargo` command-not-found fixture deterministic on CI runners.
- Ignored generated validation runtime project artifacts.

### Security / Privacy

- Hook logs store metadata only: paths, pattern names, line ranges, exit codes, similarity ratios, and actions.
- Hook logs avoid file content, diff snippets, prompts, assistant responses, and test output.
- Hook log directory/file permissions are hardened on POSIX systems.
- Protected-path edit attempts are blocked by construction-gate with metadata-only feedback, and edit-drift self-skips protected paths before opening files.

### Known Limitations

- No public marketplace listing yet.
- Windows native support is untested.
- At `0.1.0`, CI ran on Ubuntu only.
- Plugin-path and marketplace-installed smoke evidence do not yet include edit-drift-detector.
- Dogfood evidence proves lifecycle reachability and controlled behavior, not real-world false-positive rate or production readiness.
- Command-safety and Bash sandboxing remain explicit non-goals.
