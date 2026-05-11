# Troubleshooting

Operational guide for pausing, removing, debugging, and reporting issues with
`claude-meta-skills` in real Claude Code projects.

This guide is intentionally conservative. Hooks can block or modify work at
Claude Code lifecycle boundaries, so the safest recovery path is to identify
which install mode you are using, pause or remove only the relevant hook source,
then preserve redacted evidence before changing behavior.

## First triage

Run these from the project where Claude Code is using the hooks:

```bash
pwd
test -f .claude/settings.json && jq '.hooks // {}, .disableAllHooks // false' .claude/settings.json
test -f .claude/settings.local.json && jq '.hooks // {}, .disableAllHooks // false' .claude/settings.local.json
claude plugin list --json 2>/dev/null || true
```

If this repository is available locally, run the read-only doctor from the
source checkout:

```bash
cd /path/to/claude-meta-skills
make doctor TARGET=/path/to/project
```

The doctor checks source files, expected local install wiring, copied hook
files, copied-file drift from the current checkout, `disableAllHooks`, optional
tool availability, and the metadata log location. It does not install,
uninstall, invoke hooks, or print raw log contents.

Then open Claude Code's `/hooks` menu. The menu is read-only, but it shows
which hook event, matcher, handler, command, and source file are active. Sources
to look for:

- `Project` or `Local`: hooks came from `.claude/settings.json` or
  `.claude/settings.local.json`.
- `Plugin`: hooks came from a Claude Code plugin's `hooks/hooks.json`.
- `User`: hooks came from `~/.claude/settings.json`.
- `Built-in` or `Session`: not from this repository.

Also run `/status` in Claude Code when you need to confirm the active project,
model, and environment before filing an issue.

If you only need evidence, do not edit settings yet. Generate a redacted report
from this repo:

```bash
cd /path/to/claude-meta-skills
make report-dogfood
```

The report files under `.context/reports/` are gitignored and use
`--real-only --redact`. Prefer those over sharing the raw
`~/.claude/meta-skills-log.jsonl`.

## Pause or remove hooks

### Temporary pause

Claude Code supports a broad hook pause with `disableAllHooks`. Put it in a
personal/local settings file when possible so the pause is not committed for the
team:

```json
{
  "disableAllHooks": true
}
```

Use this when you are blocked and need to finish a controlled manual operation.
Remove it or set it back to `false` afterward. Claude Code's hook docs state
that there is no built-in way to disable one configured hook while keeping it in
place; individual hook disablement means editing or removing that hook entry.
Lower-scope settings cannot disable hooks forced by managed/admin policy.

If `construction-gate` is blocking edits to `.claude/settings*` or
`.claude/hooks/`, make the settings change from a shell or editor outside the
blocked Claude Code tool call.

### Local install removal

For projects installed with this repository's local installer:

```bash
cd /path/to/claude-meta-skills
./install.sh /path/to/project --uninstall
# or
make uninstall TARGET=/path/to/project
```

The uninstaller removes only hook commands whose path contains
`.claude/hooks/meta-skills/`, deletes `.claude/hooks/meta-skills/`, and preserves
unrelated hooks, unrelated settings, and `CLAUDE.md`. If `.claude/settings.json`
exists and cannot be parsed safely, uninstall stops before deleting copied hook
files.

### Plugin install removal

For plugin or marketplace installs, do not use `install.sh`. Use Claude Code's
plugin tooling:

Type these inside Claude Code:

```text
/plugin
/plugin disable claude-meta-skills@<marketplace-name>
/plugin uninstall claude-meta-skills@<marketplace-name>
/reload-plugins
```

CLI equivalents are available when you know the installed plugin id and scope:

```bash
claude plugin list --json
claude plugin disable claude-meta-skills@<marketplace-name> --scope local
claude plugin uninstall claude-meta-skills@<marketplace-name> --scope local --keep-data
```

Use the scope where the plugin was installed: `user`, `project`, or `local`.
When in doubt, inspect `/plugin` first.

## Common symptoms

| Symptom | Likely cause | What to do |
|---|---|---|
| `/hooks` shows no meta-skills hooks | Not installed in this project, plugin disabled, managed policy blocks hooks, or wrong working directory | Check `.claude/settings*.json`, `claude plugin list --json`, and the project path Claude Code opened. Reinstall only after confirming the intended install mode. |
| All hooks are silent | `disableAllHooks` is set, plugin disabled, or hook source not loaded | Check `/hooks` source labels and `jq '.disableAllHooks // false' .claude/settings*.json`. |
| `construction-gate` blocks `.env`, lock files, `.claude/settings*`, or `.claude/hooks/` | Protected-path policy is doing its job | If intentional, pause hooks temporarily or edit `hooks/construction-gate/rules.json` in the installed copy/source you actually use. Do not ask Claude to retry the same blocked write. |
| `completion-verifier` blocks Stop repeatedly | The detected test command is failing or unavailable | Run the command yourself from the project root. Fix the failing test, add a project-level `Makefile test:` target, or ensure required tools are in `PATH`. |
| `silent-file-verifier` warns `warn-missing` or `warn-empty` | Claude Code reported a successful file operation but the file is missing or unexpectedly zero bytes afterward | Inspect the file path and any concurrent formatter/watcher. Do not assume the write succeeded until the file content is visible on disk. |
| `context-recovery` modifies `CLAUDE.md` | PreCompact wrote a recovery block before compaction | Expected behavior. Keep the block if it helps recovery; remove it manually when the session state is no longer useful. |
| `edit-drift-detector` does not appear for a failed Edit | Claude Code's built-in exact-match validation rejected the tool call before `PreToolUse` hook dispatch | Expected for total `old_string` misses. The hook covers fuzzy drift for Edit payloads that reach `PreToolUse`. |
| Analyzer top paths are validation fixtures | Raw log contains harness/manual noise | Use `./testing/analyze-log.py --real-only --redact` or `make report-dogfood`. Do not use raw top paths as product evidence. |
| Plugin install uses old hook behavior after source edits | Plugins are copied into a cache when installed | For source-tree development, use `claude --plugin-dir .`. For installed plugins, run plugin update/reinstall and `/reload-plugins`. |
| Hook works in harness but not in a live session | Lifecycle reachability differs from constructed stdin tests | Check `/hooks` matcher/source, the real tool name, working directory, and known caveats in the hook README. Add a live smoke before claiming support. |

## Hook-specific checks

### `edit-drift-detector`

The hook only runs on `PreToolUse:Edit` payloads that Claude Code dispatches.
Claude Code's own Edit validation can reject an `old_string` before any hook
gets stdin. To debug:

```bash
./validation/harness.sh edit-drift-detector
./testing/analyze-log.py --real-only --redact
```

If live evidence is missing, use a disposable project and a real Edit call whose
`old_string` exists but whose replacement would clearly drift from the intended
nearby context. Do not use protected paths; `construction-gate` intentionally
runs first.

### `construction-gate`

The installed matcher is `Write|Edit|MultiEdit|NotebookEdit`. The protected
patterns live in `hooks/construction-gate/rules.json` and are mirrored in the
hook's fallback defaults. To debug:

```bash
./validation/harness.sh construction-gate
python3 - <<'PY'
import ast, json, pathlib, re
hook = pathlib.Path("hooks/construction-gate/hook.py").read_text()
defaults = ast.literal_eval(re.search(r"DEFAULT_PATTERNS = (\[[\s\S]*?\])", hook).group(1))
rules = json.loads(pathlib.Path("hooks/construction-gate/rules.json").read_text())["protected_patterns"]
print(defaults == rules)
PY
```

If you need a project-specific exception, edit the installed `rules.json` in
that project or pause hooks briefly. Do not weaken the source repo's default
rules unless the exception is generally safe for most users.

### `silent-file-verifier`

The normal path is silent. It logs only anomalies after successful
`Write|Edit|MultiEdit|NotebookEdit` tool calls. To debug:

```bash
./validation/harness.sh silent-file-verifier
./testing/analyze-log.py --real-only --redact
```

A lack of log entries during normal writes is expected. Proving this hook in a
live session requires a controlled fault such as a watcher that deletes or
truncates the file after Claude Code writes it.

### `completion-verifier`

The hook runs on `Stop` and blocks completion when the selected project test
command fails. To debug:

```bash
make test
./validation/harness.sh completion-verifier
```

In a real project, run the same test command from the same working directory
that Claude Code is using. If the project has nested packages, prefer a
top-level `Makefile test:` target so the hook has a stable command.

### `context-recovery`

The hook runs on `PreCompact` and writes an auto-generated block into
`CLAUDE.md`. To debug:

```bash
./validation/harness.sh context-recovery
sed -n '/post-compact-recovery-start/,/post-compact-recovery-end/p' CLAUDE.md
```

The block is state capture, not persistent memory. It should contain branch,
recent commits, modified files, reminders, and any custom compact instruction
text Claude Code passed to the hook.

## Evidence to include in an issue

Share redacted metadata, not private project content:

- Claude Code version: `claude --version`
- Install mode: local installer, `--plugin-dir`, marketplace/plugin install, or
  custom/manual settings.
- Operating system: macOS, Linux, WSL, or Windows native.
- Hook name, lifecycle event, and tool name from `/hooks`.
- Redacted dogfood report:

  ```bash
  make report-dogfood
  ```

- Relevant hook message shown to Claude Code, with any file-content snippets,
  test output, prompts, or proprietary paths redacted before sharing.
- Redacted settings snippet showing the hook command and matcher.
- Whether `disableAllHooks` is set in user, project, or local settings.

Do not share raw transcripts, prompts, assistant responses, `.env` files,
proprietary source code, or raw `~/.claude/meta-skills-log.jsonl` unless you have
reviewed it locally.

## What not to do

- Do not run `git reset --hard` in your project just because a hook blocked a
  tool call.
- Do not retry the same blocked write repeatedly. Read the hook message and
  change the plan.
- Do not edit committed `.claude/settings.json` to pause hooks for only your
  machine; prefer `.claude/settings.local.json` or plugin local scope.
- Do not use `install.sh --uninstall` for plugin installs.
- Do not delete Claude Code plugin cache directories as the first response to a
  plugin problem. Try `/plugin`, `claude plugin update <plugin>`,
  `claude plugin uninstall <plugin>`, and `/reload-plugins` first.
- Do not claim real false-positive rates from synthetic harness tests. Use live
  dogfood reports for lifecycle evidence and treat production rate claims as
  future work.

## Sources checked

This guide is based on current repo behavior and these external references:

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Claude Code settings reference: https://code.claude.com/docs/en/settings
- Claude Code plugin docs: https://code.claude.com/docs/en/plugins
- Claude Code plugin marketplace docs: https://code.claude.com/docs/en/plugin-marketplaces
- Claude Code discover/install plugin docs: https://code.claude.com/docs/en/discover-plugins
- Adjacent project categories already tracked in [PUBLISHING.md](PUBLISHING.md):
  workflow methodology, command safety, persistent memory, language-specific
  quality hooks, observability dashboards, and marketplaces.
