# edit-drift-detector

PreToolUse hook on Edit that catches recall-vs-observed failures: when Claude drafts an `old_string` from memory that doesn't match the actual file content, this hook blocks the edit and provides correction context.

## What it catches

- **Recall drift** — `old_string` close to actual content but with wrong words (e.g., variable name memorized incorrectly).
- **Stale content** — `old_string` matches a previous version of the file but not the current state.
- **Complete mismatch** — `old_string` from memory of a different file.
- **Indentation drift** — tabs vs spaces mismatches (similar scope to claude-tab-fix, but generalized).

## What it intentionally doesn't catch

- **Trailing whitespace differences** — pass-through; below the recall-drift threshold (see Design decisions).
- **File-doesn't-exist** — pass-through; let Edit's own error handling surface that.
- **Correctness of `new_string`** — out of scope; this hook only verifies `old_string` matches what's there.

## Installation

Add to `.claude/settings.json` (project-level) or `~/.claude/settings.json` (global):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/edit-drift-detector/hook.py\""
          }
        ]
      }
    ]
  }
}
```

Requires Python 3.7+ in PATH. Uses stdlib only — no external dependencies.

## How it works

1. Reads JSON from stdin (Claude Code's PreToolUse payload).
2. Extracts `tool_input.file_path` and `tool_input.old_string`.
3. If file doesn't exist or can't be read → exit 0 (allow).
4. If `old_string` appears verbatim in file content → exit 0 (allow).
5. If trailing-whitespace-normalized match exists → exit 0 (allow).
6. Otherwise, finds closest matching region via `difflib.SequenceMatcher`. If similarity ≥ 0.6, surfaces the actual file content at that location. If no fuzzy match, reports no-close-match.
7. Exit 2 with stderr feedback (constructive by default; see `messages.json`).

## Design decisions

- **Whitespace-only differences pass.** Trailing-whitespace mismatches are below the recall-drift threshold the hook is designed to catch. Blocking on them creates false positives without meaningful catches. Internal whitespace (tabs vs spaces) is treated as a real mismatch — that's actual drift.

- **File-doesn't-exist passes.** Out of scope. Claude Code's own error handling produces a clear message; the hook adds nothing here.

- **Closest-match similarity threshold: 0.6.** Below this, no fuzzy match suggested; message indicates content may be from a different file or completely rewritten.

- **Constructive feedback by default.** Hook reads `messages.json` and uses the version named in `default` field. Both `constructive` and `punitive` versions ship; switch `default` to A/B test in Phase 2+.

- **Exit code 2 + stderr for blocking.** Per Claude Code hooks documentation. JSON-based blocking via `permissionDecision: deny` is an alternative; will switch if reliability issues surface (see Known limitations).

- **Malformed input → allow.** If stdin JSON is unparseable, hook exits 0. Don't block legitimate edits when the hook itself can't function.

- **`replace_all: true`** — hook checks `old_string` exists in file; doesn't count occurrences. Single match is sufficient to pass.

## Known limitations

- **GitHub issue #13744** — PreToolUse exit 2 has been reported as unreliable for blocking Edit in some Claude Code versions. If observed, switch to JSON-based blocking (`{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "..."}}` with exit 0).

- **GitHub issue #15528** — PreToolUse hooks reading the target file can race with Claude Code's own file state ("File has been unexpectedly modified" errors). This hook is read-only on the target file and does not write or modify, so it should not trigger this race directly. Worth monitoring in real usage.

- **GitHub issue #11807** — PreToolUse hook success can freeze the VS Code extension (terminal Claude Code unaffected). Test on target environment before relying.

- **Multi-line `old_string` with internal blank lines** — `difflib`'s similarity may underestimate match quality. The 0.6 threshold is chosen to be permissive; tune in Phase 2+ if false negatives surface.

- **Large files (10K+ lines)** — sliding-window comparison is O(file_lines × old_lines × line_chars). For very large files with multi-line `old_string`, latency may exceed the 500ms target. Performance test in `validation/test-cases/edit-drift-detector/10-large-file-match/` covers up to 1500 lines.

## Coexistence with other hooks

When this hook is installed alongside `silent-file-verifier` and `completion-verifier`:

- This hook fires PreToolUse on Edit. If it blocks (exit 2), the Edit is cancelled and silent-file-verifier's PostToolUse does NOT fire (correct: there's nothing to verify when the Edit was prevented).
- Stop hook (completion-verifier) is independent and fires after Claude finishes responding, regardless of any Edit blocks during the response.

Behavior documented per Claude Code lifecycle docs; not validated by the harness (which tests each hook in isolation). Real-world coexistence worth a spot-check when all three hooks are installed in an actual Claude Code session.

## Additional known limitations

- **Relative paths untested.** All test fixtures use absolute paths via `{{FIXTURE_PATH}}` substitution. Real Claude Code sometimes provides relative paths; the hook calls `os.path.exists(file_path)` directly, which resolves relative to the hook process's cwd, not necessarily Claude's cwd. Behavior on relative paths is therefore uncertain. Workaround: callers passing relative paths should ensure the hook is invoked from the same cwd Claude sees.
- **Line endings (`\r\n` vs `\n`) treated as real content differences.** A file with Windows line endings vs an `old_string` with Unix line endings will not match exactly and will not normalize. Design decision: line endings carry meaning in many codebases (config files, generated files, OS-specific scripts), so the hook blocks. If you want to ignore line-ending differences, normalize before passing to Edit.
- **Large files (10K+ lines).** Sliding-window comparison is O(file_lines × old_lines) for similarity scoring. For very large files with multi-line `old_string`, latency may exceed the 500ms target. The included 1500-line test (case 10) completes well under target; 10K+ lines untested.
- **Binary files: blocks rather than skips.** Test 11 confirms the hook reads binary content (with `errors="replace"`) without crashing, but a text `old_string` won't match binary content and the hook will block with a no-close-match message. This is correct behavior (binary files shouldn't be edited via Edit anyway), but the message could be improved to suggest "this file appears to be binary; use Write to replace it instead."

## Performance

- Target: <500ms per invocation on files up to 1500 lines.
- Measured: see `validation/results/edit-drift-detector-*.json` for current numbers.

## Testing

```bash
cd validation
./harness.sh edit-drift-detector
```

11 test cases covering should-block (6) and should-pass (5). Fixtures and expected outcomes in `validation/test-cases/edit-drift-detector/`.

## Notes on prior art

- **claude-tab-fix** (github.com/WithHolm/claude-tab-fix) handles the indentation-specific case (tabs vs spaces between Read output and Edit `old_string`) via fuzzy line-similarity. This hook generalizes the approach to all `old_string` mismatches, not just indentation.

- **disler/claude-code-hooks-mastery** demonstrates PreToolUse blocking patterns; this hook follows similar structural conventions but adds fuzzy-match correction context.
