# Release checklist

This is the reusable release runbook for `claude-meta-skills`.

Release target: **`v0.1.4` technical preview**.
Previous published release: **`v0.1.3` technical preview**.

Keep future releases in the `0.x` technical-preview line while the project lacks public marketplace listing, Windows CI, and production false-positive data. Reserve `v1.0.0` for a stable public support contract.

## Release principles

- Keep release claims narrower than the evidence.
- Do not claim production readiness or zero real-world false positives.
- Treat dogfood evidence as lifecycle evidence, not production statistics.
- Keep local install and plugin/marketplace install paths clearly separated.
- Review release docs with Shadi and Caleb before tagging any release.

## Pre-release gate

Run from a clean, synced `main`:

```bash
cd /Users/shadi/conductor/repos/claude-meta-skills
git fetch origin --prune
git switch main
git pull --ff-only origin main
git status --short --branch
git log --oneline --decorate -5
```

Expected:

- branch is `main`
- local `main` equals `origin/main`
- no tracked diffs
- no untracked runtime fixtures

## Required validation

Run:

```bash
git diff --check
bash -n install.sh
bash -n testing/test-installer-idempotency.sh
make help
make test-plugin
make test-marketplace
VERSION=v0.1.4  # replace with the target release version
make test-release VERSION="$VERSION"
make test-validation-lock
make test-validation-harness
make test-repo-hygiene
make test-doctor
make test-analyzer
make test-installer
```

Run the full hook suite without polluting the active dogfood log:

```bash
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
HOME="$TEST_HOME" make test
```

Run the Stop-hook environment regression without polluting the active dogfood log:

```bash
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
HOME="$TEST_HOME" CLAUDE_PROJECT_DIR="$PWD" make test-stop-env
```

Expected:

- plugin package regression passes
- marketplace package regression passes
- release metadata version check passes for the target version
- validation harness lock regression passes
- analyzer regression passes
- installer lifecycle regression passes
- `make test` passes `93/93`
- `make test-stop-env` passes `93/93`
- real dogfood log line count does not change during validation

## Dogfood evidence refresh

Generate redacted local reports:

```bash
make report-dogfood
```

Expected:

- all five hooks have real-session evidence
- missing real-session evidence is `(none)`
- reports are redacted before sharing
- reports stay local unless explicitly approved for commit
- `git status --short .context` does not show the generated report files

Current baseline evidence is summarized in `testing/DOGFOOD-BASELINE.md`.

## Smoke tests

Before tagging a public technical preview, run at least these disposable smoke tests:

1. Local install/uninstall smoke:
   - install into a temp project
   - include an existing unrelated hook
   - include a target path with spaces
   - confirm 5 meta-skills commands after install
   - confirm 0 meta-skills commands after uninstall
   - confirm unrelated hooks/settings and `CLAUDE.md` are preserved
   - confirm no-op uninstall creates no new backup

2. Plugin-path smoke:
   - open a disposable project with `claude --plugin-dir /path/to/claude-meta-skills`
   - prove construction-gate, silent-file-verifier, completion-verifier, and context-recovery still fire from plugin paths

3. Marketplace-installed smoke:
   - install from the local marketplace catalog in isolated Claude config/cache dirs
   - open a disposable project with that installed plugin
   - prove construction-gate, silent-file-verifier, completion-verifier, and context-recovery still fire from installed plugin paths

4. Edit-drift proof decision:
   - keep the documented caveat that edit-drift has non-marketplace controlled live evidence plus synthetic validation
   - do not claim marketplace-installed edit-drift block proof unless a future Claude Code lifecycle exposes the Edit payload to PreToolUse before built-in `old_string` validation

## Version and changelog

Before tagging the target release:

1. Set `VERSION` to the target tag.
2. Update `.claude-plugin/plugin.json` to the intended release version.
3. Move the target release notes from `CHANGELOG.md` `Unreleased` into a dated release section.
4. Run `make test-release VERSION="$VERSION"`.
5. Confirm `.claude-plugin/marketplace.json` still points at the intended plugin metadata and does not duplicate the plugin version.
6. Confirm `PUBLISHING.md` safe claims still match evidence.
7. Confirm `README.md` install, validation, dogfood, and limitations sections still match the current repo.
8. Commit the dated changelog/release-doc changes before tagging:

```bash
VERSION=v0.1.4
git diff --check
git status --short
git add CHANGELOG.md RELEASE.md PUBLISHING.md README.md testing/DOGFOOD-BASELINE.md .gitignore .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs(release): prepare ${VERSION}"
git status --short --branch
```

Expected:

- the dated changelog commit is on `main`
- working tree is clean before tagging
- `git log --oneline --decorate -3` shows the release-doc commit at `HEAD`
- all intended release docs, metadata, and ignore-rule updates are included in the commit

## Tagging

Only after the gates above pass and the dated changelog commit is `HEAD`, publish `main` first and verify the remote tip before creating the tag:

```bash
VERSION=v0.1.4
git push origin main
git fetch origin --prune
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git tag -a "$VERSION" -m "$VERSION technical preview"
git push origin "$VERSION"
```

Then create GitHub release notes from `CHANGELOG.md`.

## Release notes shape

Use this structure:

```markdown
## Summary

Technical preview of claude-meta-skills: a local Claude Code reliability hook suite with synthetic harness validation, CI, controlled dogfood evidence, installer lifecycle tests, read-only doctor diagnostics, and plugin scaffold.

## Highlights

- 5 hooks covering edit verification, protected paths, ghost writes, completion tests, and pre-compaction recovery.
- 93/93 synthetic harness validation tests.
- Controlled live Claude Code session evidence for all five hooks.
- Local installer/uninstaller with lifecycle tests.
- GitHub Actions validation on PRs and main.
- Plugin scaffold and local marketplace catalog validation.

## Caveats

- Technical preview, not production proven.
- No public marketplace listing yet.
- Windows native untested.
- Dogfood evidence is controlled lifecycle evidence, not real-world false-positive statistics.
- Command safety and Bash sandboxing are out of scope.
```

## Sources

- Keep a Changelog: https://keepachangelog.com/en/1.0.0/
- Semantic Versioning 2.0.0: https://semver.org/
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugin marketplace docs: https://code.claude.com/docs/en/plugin-marketplaces
