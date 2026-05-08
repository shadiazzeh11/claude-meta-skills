# silent-file-verifier

PostToolUse hook on `Write|Edit|MultiEdit|NotebookEdit` that verifies the file actually materialized on disk after the operation. Catches the documented "ghost file" problem (Claude Code GitHub issues + community reports).

## What it catches

- Write reported success but file doesn't exist on disk.
- Write reported success but file is 0 bytes when content was non-empty.

## What it intentionally doesn't catch

- Edit operations where file size becomes 0 (Edit doesn't have a `content` field; size check is Write-only).
- Successful writes with intentionally empty content (`content: ""` on Write).
- File-content correctness (out of scope; only existence + non-zero size).

## Installation

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/silent-file-verifier/hook.py\""
          }
        ]
      }
    ]
  }
}
```

## How it works

1. Reads JSON from stdin.
2. Extracts `tool_name` and `tool_input.file_path`.
3. If file doesn't exist → emit `additionalContext` warning, exit 0.
4. If `tool_name == "Write"` AND `content` was non-empty AND file size is 0 → emit warning, exit 0.
5. Otherwise → exit 0 silently (no stdout output).

## Important: PostToolUse can't block

PostToolUse hooks fire AFTER the tool ran. Even if the hook detects a problem, the operation already completed. This hook provides feedback via `additionalContext` so Claude sees the discrepancy on the next turn and can correct (e.g., retry with verified path, investigate why file is empty).

Exit code 2 on PostToolUse shows error feedback to Claude but does not undo the operation. This hook always exits 0 (uses `additionalContext` for warnings) to avoid confusing Claude with "blocked" framing on operations that already happened.

## Design decisions

- **Edit operations: existence check only, no size check.** Edit's `tool_input` doesn't include `content` in the same shape as Write; can't compute expected size. Edit reducing a file to 0 bytes is a legitimate operation (full-file replacement with empty string).

- **Empty Write of empty content: pass silently.** If `tool_input.content == ""`, a 0-byte file is correct. Don't warn.

- **`additionalContext` over `decision: block`.** PostToolUse blocking shows error to Claude but doesn't undo the action. `additionalContext` is the right channel for "here's something to consider on your next turn."

- **Constructive feedback default.** `messages.json` defines `missing_file` and `missing_file_punitive` versions for A/B testing.

## Known limitations

- **Race conditions on networked filesystems.** If the file path resolves to a remote mount with high latency, this hook may fire a missing-file warning before the file fully syncs. Mitigation: hooks run synchronously after the tool, so this is a narrow window; document and accept.

- **Symlinks.** `os.path.exists` follows symlinks. If Claude wrote to a path through a broken symlink, the hook will flag it (correct behavior).

- **Permissions.** If the file exists but the hook lacks read permission to check size, hook exits 0 silently rather than warning. This is intentional — permission errors aren't "ghost file" problems.

## Coexistence with other hooks

When this hook is installed alongside `edit-drift-detector` and `completion-verifier`:

- This hook fires PostToolUse on `Write|Edit|MultiEdit|NotebookEdit`. If edit-drift-detector blocked the Edit at PreToolUse, the tool didn't execute and this hook does NOT fire (per Claude Code lifecycle docs: PostToolUse fires only on successful tool execution).
- This hook never blocks; its warnings via `additionalContext` are visible to Claude on subsequent turns. completion-verifier's Stop check is independent.

Behavior documented per Claude Code lifecycle docs; not validated by the harness.

## Additional known limitations

- **Tool coverage extended in Phase 2.5: matcher is now `Write|Edit|MultiEdit|NotebookEdit`.** The hook's `file_path` extraction falls back to `notebook_path` if `file_path` is missing (NotebookEdit may use the latter). Test 07 verifies MultiEdit coverage; NotebookEdit is covered by code path but not by a dedicated test fixture (NotebookEdit operates on .ipynb files which are JSON; constructing a meaningful test requires a notebook fixture).
- **No content correctness check.** This hook verifies the file exists and (for Write) that size is non-zero when content was non-empty. It does NOT verify that the file content matches what was supposed to be written. A Write could succeed, file size could be non-zero, but content could be wrong (e.g., wrong encoding, partial write, write to wrong path that happens to have an existing non-empty file). Out of scope; covered partially by Claude's own diff verification on subsequent reads.
- **File-path-is-actually-a-directory edge case.** If `file_path` points to an existing directory (rather than a file), `os.path.exists` returns True and the hook passes silently. `os.path.getsize` on a directory returns the directory entry size, not file size. This is a degenerate case (Write to a directory shouldn't happen via Claude Code) but worth noting; the hook would not catch it.
- **Networked filesystem race.** If the file path resolves to a remote mount with eventual consistency, the hook may fire its missing-file warning before the file fully syncs. PostToolUse fires synchronously after the tool reports complete, so this window is narrow but not zero.

## Performance

- Single `os.path.exists` + `os.path.getsize` call. Sub-millisecond.
- Hook startup (Python interpreter): typically <50ms total.

## Testing

```bash
cd validation
./harness.sh silent-file-verifier
```

7 test cases. See `validation/test-cases/silent-file-verifier/`.
