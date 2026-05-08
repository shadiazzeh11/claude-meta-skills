# silent-file-verifier

PostToolUse hook on Write and Edit that verifies the file actually materialized on disk after the operation. Catches the documented "ghost file" problem (Claude Code GitHub issues + community reports).

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
        "matcher": "Write|Edit",
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

## Performance

- Single `os.path.exists` + `os.path.getsize` call. Sub-millisecond.
- Hook startup (Python interpreter): typically <50ms total.

## Testing

```bash
cd validation
./harness.sh silent-file-verifier
```

6 test cases. See `validation/test-cases/silent-file-verifier/`.
