#!/usr/bin/env bash
# Git repo with tracked/untracked work plus untracked local install noise.
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cd "$PROJ" || exit 1
rm -rf .git .claude CLAUDE.md notes *.txt *.ignored .gitignore 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "# Test Project" > CLAUDE.md
echo "*.ignored" > .gitignore
echo "v1" > tracked.txt
git add CLAUDE.md .gitignore tracked.txt
git commit -q -m "Initial commit"

echo "v2 modified" > tracked.txt
mkdir -p notes
echo "draft plan" > notes/draft.md
echo "ignored local output" > local.ignored
mkdir -p .claude/hooks/meta-skills/context-recovery
mkdir -p .claude/hooks/meta-skills/completion-verifier
echo "copied context hook" > .claude/hooks/meta-skills/context-recovery/hook.py
echo "copied stop hook" > .claude/hooks/meta-skills/completion-verifier/hook.py
echo '{"hooks":{}}' > .claude/settings.json
echo '{"old_hooks":{}}' > .claude/settings.json.backup-1234567890
echo '{"older_hooks":{}}' > .claude/settings.json.backup-1234567890-1
