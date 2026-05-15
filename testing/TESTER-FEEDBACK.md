# Tester feedback form

Use this after `testing/NEW-USER-SMOKE.md` or any disposable external smoke.
Do not include private code, secrets, raw prompts, raw logs, or real project
paths. Prefer redacted analyzer output when sharing hook evidence.

## Tester and environment

```markdown
Tester:
Date:
OS / version:
Shell:
Claude Code version:
Python version:
jq version:
make version:
Repo tag or commit tested:
Install mode: local install.sh / plugin-dir / marketplace / other
```

## Setup result

```markdown
Did Step 0 precheck pass? yes/no
If no, what was missing?

Did clone/tag checkout pass? yes/no
Did make test-release pass? yes/no
Did make test-plugin pass? yes/no

Did the disposable project baseline test pass before installing hooks? yes/no
If no, stop and paste only the short error summary.
```

## Install and doctor

```markdown
Did install.sh complete? yes/no
Did doctor.sh report 0 FAIL? yes/no
WARN lines, if any:

Could you tell what files were installed? yes/no
Did anything look surprising or unsafe?
```

## Claude Code hook behavior

```markdown
Did completion-verifier block the intentionally failing-test stop? yes/no
Was the hook message understandable? yes/no
Did it explain what to do next? yes/no
Did it expose anything that felt too private? yes/no

Did recovery back to passing tests work? yes/no
After recovery, was git diff clean for src/app.py and tests/test_app.py? yes/no
```

## Uninstall

```markdown
Did uninstall complete? yes/no
Was .claude/hooks/meta-skills removed? yes/no
Did any settings backup remain? yes/no/unsure
Was it clear that settings backups are expected local artifacts? yes/no
Was cleanup clear? yes/no
```

## Redacted evidence

Optional, if comfortable:

```bash
"$META_SKILLS_DIR/testing/analyze-log.py" --real-only --redact
```

Paste only the summary section. Do not paste raw `~/.claude/meta-skills-log.jsonl`
unless you reviewed it for private paths.

## Trust and product feedback

```markdown
What was confusing?
What felt safe and clear?
What felt risky?
Would you keep this installed for one week in a real repo? why/why not?
What should be changed before a public marketplace listing?
```

## Maintainer triage

Maintainers should classify the report:

```markdown
Result: pass / environment-blocked / instruction-bug / hook-bug / user-confusion
Hook(s) involved:
Install path:
Action needed:
Follow-up issue/PR:
```
