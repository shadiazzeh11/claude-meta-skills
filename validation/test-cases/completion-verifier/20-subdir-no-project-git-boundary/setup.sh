#!/usr/bin/env bash
# Create a nested git boundary with no recognized project config. The parent
# project intentionally has a failing test so this case proves live
# CLAUDE_PROJECT_DIR-bounded discovery does not leak across the nested repo.
PROJ="$TEST_DIR/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/vendor/subrepo/src/pkg"
cat >"$PROJ/pyproject.toml" <<'EOF'
[project]
name = "parent-should-not-run"
version = "0.0.0"
EOF
cat >"$PROJ/test_parent_should_not_run.py" <<'EOF'
import unittest


class ParentShouldNotRun(unittest.TestCase):
    def test_parent_tests_would_fail(self):
        self.fail("parent tests should not run from nested git repo")


if __name__ == "__main__":
    unittest.main()
EOF
cd "$PROJ/vendor/subrepo" || exit 1
rm -rf .git 2>/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test"
