# completion-verifier

Stop hook that runs the project's test command before allowing Claude to finish responding. Catches the most-cited Claude Code complaint: claiming "done" without verifying tests pass.

## What it catches

- Tests failing while Claude declares the task complete.
- Build/check failures that should block completion.
- Premature stop on projects with verifiable test suites.

## What it intentionally doesn't catch

- Projects with no recognizable type (no `package.json`, `Cargo.toml`, `pyproject.toml`, `setup.py`, `go.mod`, or `Makefile`) → pass-through.
- Exploration sessions with no file-modifying tool usage (when transcript is readable) → pass-through.
- Sessions where the test command isn't installed → pass-through with warning.
- Long-running test suites exceeding 30s → pass-through with timeout warning.

## Installation

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/completion-verifier/hook.py\""
          }
        ]
      }
    ]
  }
}
```

Stop hooks don't take a matcher (they fire on the Stop event itself).

## How it works

1. Reads JSON from stdin.
2. **Anti-loop check (mandatory):** if `stop_hook_active` is `true`, exit 0 immediately. Without this, the hook creates an infinite loop (issues #3573, #10205).
3. Resolves the project root for test detection:
   - `$CLAUDE_PROJECT_DIR` is used as the trusted upper bound when present.
   - Otherwise, the hook walks upward from `cwd` until it finds a supported config file or reaches the nearest git root.
4. Detects project type via config-file presence at that resolved root, in this priority order:
   - `package.json` → `npm test`
   - `Cargo.toml` → `cargo test`
   - `pyproject.toml` / `setup.py` → Python test command:
     - pytest-configured projects → local `.venv`/`venv` Python with `-m pytest`, when available
     - otherwise → `python3 -m unittest discover -v`
   - `go.mod` → `go test ./...`
   - `Makefile` → `make test`
5. Reads `transcript_path` to check whether any `Write`, `Edit`, `MultiEdit`, or `NotebookEdit` calls happened in the session. The scanner accepts current `tool_use` blocks plus common `tool_call` wrapper shapes. If transcript readable AND no writes → exit 0 (exploration session).
6. Runs the test command with a 30s timeout from the resolved project root.
7. Allow on success (exit 0). Block on failure with JSON `{"decision": "block", "reason": ...}` containing the last 50 lines of test output.
8. Timeout or command-not-found → exit 0 with a top-level `systemMessage` warning (don't block when can't verify).

## Design decisions

- **Python prefers pytest only when the project declares it and the runner is already installed.** `pyproject.toml` / `setup.py` projects default to `python3 -m unittest discover -v` for stdlib availability. If pytest is declared via `[tool.pytest...]`, `pytest.ini`, or project dependencies, the hook first looks for pytest in a local `.venv` / `venv` Python and runs that interpreter with `-m pytest`. If pytest is declared but unavailable, the hook warns and allows Stop instead of blocking on a system-Python import failure.

- **Transcript-unreadable defaults to running tests.** Per spec: "accept this limitation and document it." False-positive risk acknowledged in Known limitations.

- **30-second timeout.** Long suites get a warning, not a block. When the process emits output before timing out, the warning includes the last output lines so the user can see why verification was inconclusive. Test suites exceeding this should run separately (e.g., CI), not on every Claude stop.

- **Last 50 lines of output.** Per HumanLayer's lesson: full test output (often thousands of lines) floods Claude's context and makes the failure harder to read, not easier.

- **Test output is feedback, not telemetry.** Failing-test snippets are sent to Claude Code as Stop-block reasons so the agent can fix the problem. Timeout and missing-command snippets are emitted as top-level `systemMessage` warnings because Stop hooks do not support `additionalContext` delivery. None of those snippets are written to `~/.claude/meta-skills-log.jsonl`, which records metadata only.

- **JSON `decision: block` over exit 2.** Stop hooks have well-documented JSON-decision blocking; exit 2 also works but JSON is more explicit and permits the `reason` field.

- **Project priority: spec order.** First config file found wins. Document this so users know which command runs in mixed-config repos.

- **Parent discovery is bounded.** Subdirectory Stop events walk upward to find the project config, but `$CLAUDE_PROJECT_DIR` and nearest-git-root boundaries prevent leaking into unrelated parent repositories.

- **Constructive feedback default.** `messages.json` defines `constructive` and `punitive` versions for A/B testing in Phase 2+.

## Known limitations

- **Plugin-path live proof covers Makefile-based Stop blocking.** A local `claude --plugin-dir .` smoke session intentionally broke a disposable project's `Makefile test` path and observed this hook block Stop with the failing unittest output.
- **Issue #3573, #10205**: Stop hook infinite loops if `stop_hook_active` not checked. We check first thing; verified in test 07.

- **Issue #15813, #8564, #3019, #3046**: `transcript_path` can be stale, point to wrong file, or be missing. When transcript is unreadable, we default to running tests (false-positive risk). Documented and tested.

- **False-positive risk on exploration sessions with unreadable transcript.** If transcript can't be read AND a project has pre-existing test failures unrelated to the current Claude session, this hook will block completion. Mitigation: Claude can note "tests were already failing before this session; see [paths]" in its response, which the hook will allow on next stop attempt (`stop_hook_active` will be true).

- **Project type ambiguity.** A repo with both `package.json` and `pyproject.toml` will use npm only because `package.json` is checked first. A Makefile does not override earlier project-type matches; it is used only when no higher-priority config is present.

- **Makefile is not a Python override when `pyproject.toml` exists.** Project-type detection is first-match by config file. Python projects with a `Makefile` still use the Python command because `pyproject.toml` is checked before `Makefile`. If a project needs a custom command, configure the Python environment so the intended runner is available.

## Coexistence with other hooks

When this hook is installed alongside `edit-drift-detector` and `silent-file-verifier`:

- This hook fires only at Stop (after Claude finishes responding). Independent of any PreToolUse/PostToolUse hooks during the response.
- If edit-drift-detector blocked an Edit during the response, the corresponding transcript tool-call entry would still appear in the transcript (PreToolUse fires after Claude proposes the tool call but before it executes; the proposal is visible in transcript regardless of block outcome). transcript_has_writes treats this as a write attempt and runs tests.
- silent-file-verifier never blocks (PostToolUse can't undo); its `additionalContext` warnings are visible to Claude on subsequent turns but don't affect this hook's behavior.

Behavior documented per Claude Code lifecycle docs; not validated by the harness.

## Additional known limitations

- **Transcript schema drift risk is reduced, not eliminated.** `transcript_has_writes` recursively scans parsed JSONL lines for explicit file-modifying tool calls across `tool_use`, `tool_call`, `tool_call_delta`, and common wrapper/name fields. Unknown future transcript schemas can still be missed if they are readable but do not expose recognizable tool-call metadata. Keep periodic spot-checks against actual session transcripts.
- **Timeout output is best-effort.** When `subprocess.TimeoutExpired` fires, the hook includes any captured stdout/stderr that Python exposes on the exception. Output emitted but not flushed by the timed-out process may still be missing.
- **Anti-loop check only catches the documented loop pattern.** `stop_hook_active=true` is the documented signal Claude Code sends when forced-continuation is in progress. If a future Claude Code version changes this signal (e.g., to a different field name), the anti-loop protection silently degrades.

## Performance

- Test command timeout: 30s (configurable via positive integer `COMPLETION_VERIFIER_TIMEOUT_SECS` env var; invalid, zero, and negative values fall back to 30s).
- Hook overhead (excluding test command): typically <100ms (Python startup + transcript scan).
- Total wall-clock: dominated by the test suite itself.

## Testing

```bash
cd validation
./harness.sh completion-verifier
```

24 test cases. See `validation/test-cases/completion-verifier/`.
