# New-user smoke test

This runbook is for a friend, reviewer, or first-time external tester who wants
to evaluate `claude-meta-skills` in a disposable project.

The goal is to answer a narrow question: can a new tester install a selected
`claude-meta-skills` ref, inspect what was installed, see one useful hook fire,
recover the project, uninstall cleanly, and report confusing moments?

This is not a production trial, a marketplace install proof, or a false-positive
rate study. Do not run it in a real work repository.

## Safety rules

Stop immediately if:

- You are not in a disposable project that can be deleted.
- You are about to paste private code, secrets, customer data, or internal logs.
- Claude asks to edit secrets, `.env*`, `.git/`, `node_modules/`, lock files, or
  unrelated files.
- You see unexpected package installs, daemons, browser windows, credential
  prompts, or network activity outside the explicit `git clone` step.
- A hook message is confusing enough that you cannot tell what happened.
- You cannot verify what was installed or how to uninstall it.

Hooks run local code with the privileges of your OS user. The
`completion-verifier` hook may run the disposable project's own test command; any
side effects of those tests belong to the project under test.

## What this tests

This smoke test checks:

- An explicit local checkout ref of `claude-meta-skills` (`main`, a release tag,
  or a commit SHA).
- Local `install.sh` installation into a disposable project.
- `doctor.sh` first-run diagnostics.
- A controlled `completion-verifier` block when tests are intentionally broken.
- Recovery back to a passing disposable project.
- Uninstall clarity for copied hook files and local settings entries.

It does not check:

- Public Claude plugin marketplace installation.
- Windows native behavior.
- Production false-positive or false-negative rates.
- Bash command safety or sandboxing.
- All five hooks firing in one session.

## Environment precheck

Run this before cloning anything:

```bash
uname -a
git --version
python3 --version
jq --version
make --version
claude --version
```

Expected:

- `git`, `python3`, `jq`, `make`, and `claude` all print versions.
- The tester knows this is a disposable smoke and can delete the temp
  directories afterward.

Stop conditions:

- If `claude` is not found, stop. Install and authenticate Claude Code from the
  official Claude Code setup docs, then restart this smoke from the top.
- If `git` or `python3` is missing, stop. The local checkout and hooks need them.
- If `jq` is missing, stop. This smoke includes uninstall, and uninstall needs
  `jq` to remove hook entries from `.claude/settings.json` safely.
- If `make` is missing, stop. The release checks and disposable project test
  command use `make`.

Do not treat base-machine setup problems as plugin failures. Record them in the
report and stop.

## Step 1: clone the release

Use an explicit ref. For current pre-release tester feedback, the default
`main` ref exercises the latest runbook and code. For a released artifact audit,
set `SMOKE_REF` to a release tag or commit SHA before running the block.

```bash
RELEASE_VERSION="v0.1.5"
SMOKE_REF="${SMOKE_REF:-main}"
SMOKE_ROOT="$(mktemp -d /tmp/claude-meta-user-smoke.XXXXXX)"
export RELEASE_VERSION SMOKE_REF SMOKE_ROOT
printf 'SMOKE_REF=%s\n' "$SMOKE_REF"
printf 'SMOKE_ROOT=%s\n' "$SMOKE_ROOT"

cd "$SMOKE_ROOT"
git clone https://github.com/shadiazzeh11/claude-meta-skills.git
cd claude-meta-skills
git checkout "$SMOKE_REF"

make test-release VERSION="$RELEASE_VERSION"
make test-plugin
```

Expected:

- `git checkout "$SMOKE_REF"` succeeds.
- `make test-release VERSION="$RELEASE_VERSION"` passes.
- `make test-plugin` passes. A warning about repo-root `CLAUDE.md` not being the
  plugin context is acceptable for this repository; plugin context lives in the
  plugin skill.

## Step 2: create a disposable project

```bash
PROJECT_DIR="$(mktemp -d /tmp/claude-meta-user-project.XXXXXX)"
export PROJECT_DIR
printf 'PROJECT_DIR=%s\n' "$PROJECT_DIR"

cd "$PROJECT_DIR"
git init

python3 - <<'PY'
from pathlib import Path

files = {
    "src/__init__.py": "",
    "src/app.py": 'def label(value):\n    return f"Price: {value}"\n',
    "tests/test_app.py": (
        "import unittest\n\n"
        "from src.app import label\n\n\n"
        "class AppTests(unittest.TestCase):\n"
        "    def test_label(self):\n"
        '        self.assertEqual(label(3), "Price: 3")\n\n\n'
        'if __name__ == "__main__":\n'
        "    unittest.main()\n"
    ),
    "Makefile": "test:\n\tpython3 -m unittest discover -s tests -v\n",
}

for name, content in files.items():
    path = Path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="ascii")
    path.read_bytes().decode("ascii")
    print(f"wrote ASCII {name}")
PY

git add .
git -c user.name=Smoke -c user.email=smoke@example.invalid commit -m "initial smoke project"
make test
git status --short --branch
```

Expected:

- `make test` reports one passing test.
- `git status --short --branch` shows a clean branch.

## Step 3: install and inspect

```bash
META_SKILLS_DIR="$SMOKE_ROOT/claude-meta-skills"
export META_SKILLS_DIR
printf 'META_SKILLS_DIR=%s\n' "$META_SKILLS_DIR"

"$META_SKILLS_DIR/install.sh" "$PROJECT_DIR"
"$META_SKILLS_DIR/doctor.sh" "$PROJECT_DIR"

cd "$PROJECT_DIR"
git status --short --branch
find "$PROJECT_DIR/.claude/hooks/meta-skills" -maxdepth 2 -type f | sort
```

Expected:

- The installer copies five hooks under `.claude/hooks/meta-skills/`.
- `.claude/settings.json` exists and points to the copied local hooks.
- `doctor.sh` reports `0 FAIL`.
- Benign warnings are possible, such as optional `CLAUDE.md` or prior log
  absence. Record any `WARN` lines in the report.
- `git status` shows `.claude/` as untracked in the disposable project.

## Step 4: run the Claude Code smoke

Open Claude Code from the disposable project:

```bash
cd "$PROJECT_DIR"
claude
```

Paste this prompt:

```text
This is a claude-meta-skills release smoke test in a disposable project.

First run:
pwd
git status --short --branch
make test

Then intentionally create a failing-test state:
Edit src/app.py so label returns "Cost: {value}" instead of "Price: {value}".
Do not update tests.

Then try to stop and report whether completion-verifier blocks completion.
Do not commit, push, install anything else, or edit .claude/.
```

Expected:

- Claude changes `src/app.py`.
- `make test` fails because the test still expects `Price: 3`.
- The `completion-verifier` Stop hook blocks completion and asks the agent to
  address the failing tests or explain why they are unrelated.
- The hook message should not print prompts, source-file contents, diffs, or
  unbounded test output. A bounded relevant failure snippet is expected; in
  this tiny one-test project, that snippet may look like the whole unittest
  failure.

If no block appears, ask Claude to run `/hooks` and `make test`, then stop and
report the output. Do not keep trying random fixes.

## Step 5: recover the project

In the same Claude Code session, paste:

```text
Continue the smoke test.

Restore the disposable project to a passing state by reverting src/app.py to return "Price: {value}".

Then run:
make test
git status --short --branch
git diff -- src/app.py tests/test_app.py

Do not commit. Do not edit .claude/. Stop after reporting results.
```

Expected:

- `make test` passes.
- `git diff -- src/app.py tests/test_app.py` is empty.
- `git status --short --branch` shows only expected untracked local hook files
  and Python cache directories, if any.

## Step 6: uninstall

Run this in a normal terminal. If you opened a new terminal, first paste the
explicit `PROJECT_DIR` and `SMOKE_ROOT` values printed by the earlier steps.
Do not run uninstall with empty variables.

```bash
: "${PROJECT_DIR:?set PROJECT_DIR to the /tmp/claude-meta-user-project.* path from Step 2}"
: "${SMOKE_ROOT:?set SMOKE_ROOT to the /tmp/claude-meta-user-smoke.* path from Step 1}"
META_SKILLS_DIR="${META_SKILLS_DIR:-$SMOKE_ROOT/claude-meta-skills}"

printf 'PROJECT_DIR=%s\nSMOKE_ROOT=%s\nMETA_SKILLS_DIR=%s\n' \
  "$PROJECT_DIR" "$SMOKE_ROOT" "$META_SKILLS_DIR"

case "$PROJECT_DIR" in
  /tmp/claude-meta-user-project.*|/private/tmp/claude-meta-user-project.*) ;;
  *) echo "refusing: PROJECT_DIR is not a disposable smoke path"; exit 1 ;;
esac

case "$SMOKE_ROOT" in
  /tmp/claude-meta-user-smoke.*|/private/tmp/claude-meta-user-smoke.*) ;;
  *) echo "refusing: SMOKE_ROOT is not a disposable smoke path"; exit 1 ;;
esac

PROJECT_REAL="$(cd "$PROJECT_DIR" && pwd -P)"
SMOKE_REAL="$(cd "$SMOKE_ROOT" && pwd -P)"
case "$PROJECT_REAL" in
  /tmp/claude-meta-user-project.*|/private/tmp/claude-meta-user-project.*) ;;
  *) echo "refusing: resolved PROJECT_DIR is not a disposable smoke path"; exit 1 ;;
esac
case "$SMOKE_REAL" in
  /tmp/claude-meta-user-smoke.*|/private/tmp/claude-meta-user-smoke.*) ;;
  *) echo "refusing: resolved SMOKE_ROOT is not a disposable smoke path"; exit 1 ;;
esac

cd "$PROJECT_DIR"
"$META_SKILLS_DIR/install.sh" "$PROJECT_DIR" --uninstall

test ! -d "$PROJECT_DIR/.claude/hooks/meta-skills" && echo "meta-skills hook directory removed"
git status --short --branch
find "$PROJECT_DIR/.claude" -maxdepth 3 -type f -print 2>/dev/null || true
```

Expected:

- The uninstaller removes meta-skills hook entries from `.claude/settings.json`.
- `.claude/hooks/meta-skills/` is removed.
- Unrelated settings and `CLAUDE.md`, if present, are preserved.
- The disposable source files stay intact.
- A `.claude/settings.json.backup-*` file may remain. That is expected; the
  whole disposable project is removed during cleanup.

If the command path looks like `/claude-meta-skills/install.sh` or the target
path is empty, the shell variables were lost. Stop and rerun Step 6 with explicit
absolute paths copied from the earlier output.

## Step 7: cleanup

After the report is saved:

```bash
: "${PROJECT_DIR:?set PROJECT_DIR before cleanup}"
: "${SMOKE_ROOT:?set SMOKE_ROOT before cleanup}"

case "$PROJECT_DIR" in
  /tmp/claude-meta-user-project.*|/private/tmp/claude-meta-user-project.*) ;;
  *) echo "refusing: PROJECT_DIR is not a disposable smoke path"; exit 1 ;;
esac

case "$SMOKE_ROOT" in
  /tmp/claude-meta-user-smoke.*|/private/tmp/claude-meta-user-smoke.*) ;;
  *) echo "refusing: SMOKE_ROOT is not a disposable smoke path"; exit 1 ;;
esac

PROJECT_REAL="$(cd "$PROJECT_DIR" && pwd -P)"
SMOKE_REAL="$(cd "$SMOKE_ROOT" && pwd -P)"
case "$PROJECT_REAL" in
  /tmp/claude-meta-user-project.*|/private/tmp/claude-meta-user-project.*) ;;
  *) echo "refusing: resolved PROJECT_DIR is not a disposable smoke path"; exit 1 ;;
esac
case "$SMOKE_REAL" in
  /tmp/claude-meta-user-smoke.*|/private/tmp/claude-meta-user-smoke.*) ;;
  *) echo "refusing: resolved SMOKE_ROOT is not a disposable smoke path"; exit 1 ;;
esac

rm -rf "$PROJECT_DIR" "$SMOKE_ROOT"
```

Only run this when you are sure both variables point to the disposable smoke
directories.

## Common failure modes

| Symptom | Likely cause | What to do |
|---|---|---|
| `claude: command not found` | Claude Code is not installed or not on `PATH` | Stop, install and authenticate Claude Code separately, then restart |
| `python3: command not found` | Hooks cannot run | Stop and fix the base environment |
| `jq: command not found` | Uninstall cannot safely edit settings | Stop and install `jq` before this smoke |
| `make: command not found` | Base developer tools are missing | Stop and report environment failure |
| Disposable project baseline test fails before install | Copy/paste introduced non-ASCII whitespace or the shell mangled file creation | Stop. Report the short error and the output of `python3 --version`; do not install hooks into a broken baseline. |
| `/hooks` shows no meta-skills hooks | Wrong install target, wrong cwd, disabled hooks, or stale Claude session | Run `doctor.sh "$PROJECT_DIR"` and report output |
| No completion block appears | Test was not broken, hooks were not loaded, or Claude fixed tests before stopping | Run `make test`, `/hooks`, and stop with the output |
| Completion hook reports command missing | The project test command is unavailable | Report it; do not install extra tooling inside this smoke unless approved |
| Step 6 prints `PROJECT_DIR: parameter null or not set` | You opened a new terminal and lost the variables | Paste the explicit paths from Step 1 and Step 2 before running uninstall. |
| Uninstall cannot edit settings | Missing `jq` or invalid settings JSON | Stop; do not manually delete files unless you understand the settings diff |
| Windows native shell issues | Windows native is untested | Retry in WSL or on macOS/Linux |

## Privacy expectations

The local metadata log is `~/.claude/meta-skills-log.jsonl`.

Expected log fields include timestamps, hook names, action names, project paths,
pattern names, line ranges, similarity ratios, exit codes, byte counts, and
session IDs.

The log should not contain file contents, diff snippets, `old_string`,
`new_string`, full test stdout/stderr, prompts, assistant responses, or
environment variable values.

When sharing feedback, prefer redacted analyzer output:

```bash
"$META_SKILLS_DIR/testing/analyze-log.py" --real-only --redact
```

Do not paste raw logs unless you have checked paths and project names first.

## Report template

Prefer the "New user smoke" GitHub issue form or
`testing/TESTER-FEEDBACK.md`. If you need a plain-text fallback, use this shape:

```markdown
## New-user smoke report

OS:
Shell:
Claude Code version:
Repo ref tested:
Install mode: local install.sh

Prereq checks:
- claude --version:
- git --version:
- python3 --version:
- jq --version:
- make --version:

Release/setup:
- clone/ref checkout completed? yes/no
- make test-release completed? yes/no
- make test-plugin completed? yes/no
- disposable project baseline passed before install? yes/no

Install result:
- install.sh completed? yes/no
- doctor summary:
- any WARN/FAIL lines:
- could you tell what files were installed?
- did anything look surprising or unsafe?

Claude Code smoke:
- did /hooks show meta-skills hooks?
- did completion-verifier block the intentional failing-test stop?
- was the hook message understandable?
- did the message expose anything too private?
- did the recovery prompt lead to passing tests?

Uninstall:
- uninstall completed? yes/no
- .claude/hooks/meta-skills removed? yes/no
- anything preserved or unexpectedly changed?

Confusing, surprising, or unsafe-feeling moments:

Would you keep this installed for one week in a real repo? why/why not:
What should change before a public marketplace listing:
```

## Pass criteria

This smoke passes if:

- The tester installed into a disposable repo without private data.
- The tester could inspect what was installed.
- `completion-verifier` blocked the intentional failing-test completion.
- The tester restored the project to passing tests.
- The tester understood the local metadata log boundary.
- Disable or uninstall behavior was clear.

This smoke fails if:

- Installation scope was unclear.
- The tester could not tell what code was running.
- The test touched a real repo or private data.
- Logs included source contents, prompts, diffs, secrets, or test output.
- Uninstall or disable behavior was unclear.
- Hook messages made the tester mistrust the tool.
