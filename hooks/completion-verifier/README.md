# completion-verifier

Stop hook that runs the project's test command before allowing Claude to finish responding. Catches the most-cited Claude Code complaint: claiming "done" without verifying tests pass.

## What it catches

- Tests failing while Claude declares the task complete.
- Build/check failures that should block completion.
- Premature stop on projects with verifiable test suites.

## What it intentionally doesn't catch

- Projects with no recognizable type (no `package.json`, `Cargo.toml`, `pyproject.toml`, `setup.py`, `go.mod`, or `Makefile`) → pass-through.
- Exploration sessions with no Write/Edit usage (when transcript is readable) → pass-through.
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
3. Detects project type via config-file presence, in this priority order:
   - `package.json` → `npm test`
   - `Cargo.toml` → `cargo test`
   - `pyproject.toml` / `setup.py` → `python3 -m unittest discover -v`
   - `go.mod` → `go test ./...`
   - `Makefile` → `make test`
4. Reads `transcript_path` to check whether any Write or Edit calls happened in the session. If transcript readable AND no writes → exit 0 (exploration session).
5. Runs the test command with a 30s timeout from `cwd`.
6. Allow on success (exit 0). Block on failure with JSON `{"decision": "block", "reason": ...}` containing the last 50 lines of test output.
7. Timeout or command-not-found → exit 0 with `additionalContext` warning (don't block when can't verify).

## Design decisions

- **Python uses `unittest` discover, not `pytest`.** Reason: stdlib availability across machines. If a project uses pytest, the user can override via Makefile (`test:` target invoking pytest) which the hook will pick up via the Makefile fallback.

- **Transcript-unreadable defaults to running tests.** Per spec: "accept this limitation and document it." False-positive risk acknowledged in Known limitations.

- **30-second timeout.** Long suites get a warning, not a block. Test suites exceeding this should run separately (e.g., CI), not on every Claude stop.

- **Last 50 lines of output.** Per HumanLayer's lesson: full test output (often thousands of lines) floods Claude's context and makes the failure harder to read, not easier.

- **JSON `decision: block` over exit 2.** Stop hooks have well-documented JSON-decision blocking; exit 2 also works but JSON is more explicit and permits the `reason` field.

- **Project priority: spec order.** First config file found wins. Document this so users know which command runs in mixed-config repos.

- **Constructive feedback default.** `messages.json` defines `constructive` and `punitive` versions for A/B testing in Phase 2+.

## Known limitations

- **Issue #3573, #10205**: Stop hook infinite loops if `stop_hook_active` not checked. We check first thing; verified in test 07.

- **Issue #15813, #8564, #3019, #3046**: `transcript_path` can be stale, point to wrong file, or be missing. When transcript is unreadable, we default to running tests (false-positive risk). Documented and tested.

- **False-positive risk on exploration sessions with unreadable transcript.** If transcript can't be read AND a project has pre-existing test failures unrelated to the current Claude session, this hook will block completion. Mitigation: Claude can note "tests were already failing before this session; see [paths]" in its response, which the hook will allow on next stop attempt (`stop_hook_active` will be true).

- **Project type ambiguity.** A repo with both `package.json` and `pyproject.toml` will use npm only. Workaround: Makefile target `test:` that runs both runners; the Makefile fallback is the lowest priority but always works as user-controlled override.

## Performance

- Test command timeout: 30s (configurable via `TIMEOUT_SECS` constant).
- Hook overhead (excluding test command): typically <100ms (Python startup + transcript scan).
- Total wall-clock: dominated by the test suite itself.

## Testing

```bash
cd validation
./harness.sh completion-verifier
```

8 test cases. See `validation/test-cases/completion-verifier/`.
