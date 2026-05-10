#!/usr/bin/env python3
"""
silent-file-verifier hook for Claude Code.

PostToolUse hook on Write|Edit. Verifies the file actually exists and
has expected content after the operation. Catches the documented
"ghost file" problem where Claude reports success but the file
doesn't materialize.

PostToolUse hooks cannot block (the tool already ran). This hook
provides feedback via additionalContext so Claude sees the discrepancy
on the next turn and can correct.

Output:
  - Success case: exits 0 silently (no output).
  - Missing file: exits 0 with additionalContext warning.
  - Empty file (when content was non-empty Write): exits 0 with warning.
"""
import json
import sys
import os
from pathlib import Path
from datetime import datetime, timezone


def log_fire(hook_name, action, project, detail, session_id):
    """Append one JSON line to ~/.claude/meta-skills-log.jsonl. Best-effort; never raises.
    Detail is metadata only — no file content, no diff snippets, no test output."""
    try:
        log_dir = Path.home() / ".claude"
        log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(log_dir, 0o700)
        entry = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "hook": hook_name,
            "action": action,
            "project": project or "",
            "detail": (detail or "")[:200],
            "session_id": session_id or "",
        }
        line = json.dumps(entry, separators=(",", ":")) + "\n"
        fd = os.open(str(log_dir / "meta-skills-log.jsonl"),
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            if hasattr(os, "fchmod"):
                os.fchmod(fd, 0o600)
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    except Exception:
        pass


def resolve_file_path(file_path, payload):
    """Resolve a tool_input file_path/notebook_path against payload cwd when relative.

    Absolute paths are returned as-is. Relative paths are joined onto
    payload['cwd'] when that key is present and points to an existing
    directory; otherwise the original (relative) path is returned and
    will resolve against the hook process's cwd. The resolved path is
    intended for filesystem operations only; the original path is
    preserved for warnings and log details.
    """
    if not file_path:
        return file_path
    if os.path.isabs(file_path):
        return file_path
    cwd = payload.get("cwd", "")
    if cwd and os.path.isdir(cwd):
        return os.path.join(cwd, file_path)
    return file_path


def load_messages():
    """Load template messages from messages.json next to this script."""
    script_dir = Path(__file__).parent
    messages_path = script_dir / "messages.json"
    fallback = {
        "default": "constructive",
        "missing_file": "The {tool_name} reported success but {file_path} doesn't exist on disk. This is sometimes a path-resolution issue or a permissions problem. Verify the path with `ls`, then retry with the confirmed absolute path.",
        "missing_file_punitive": "WARNING: File {file_path} does not exist after {tool_name} operation reported success.",
        "empty_file": "The Write of {file_path} reported success but the file is 0 bytes (the content provided was non-empty, expected ~{expected_size} bytes). Verify the content was written and retry the Write if needed.",
    }
    if not messages_path.exists():
        return fallback
    try:
        with open(messages_path) as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return fallback


def emit_warning(message):
    """Emit a non-blocking PostToolUse additionalContext warning."""
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": message,
        }
    }
    print(json.dumps(output))


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})
    # Write/Edit/MultiEdit use file_path; NotebookEdit uses notebook_path.
    file_path = tool_input.get("file_path") or tool_input.get("notebook_path", "")

    if not file_path:
        return 0

    fs_path = resolve_file_path(file_path, payload)

    messages = load_messages()
    default_version = messages.get("default", "constructive")

    # Existence check
    if not os.path.exists(fs_path):
        if default_version == "constructive":
            template = messages.get("missing_file", "")
        else:
            template = messages.get("missing_file_punitive", "")
        try:
            msg = template.format(file_path=file_path, tool_name=tool_name)
        except (KeyError, IndexError):
            msg = template
        emit_warning(msg)
        log_fire(
            hook_name="silent-file-verifier",
            action="warn-missing",
            project=os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd", ""),
            detail=f"tool={tool_name} file={file_path}",
            session_id=payload.get("session_id", ""),
        )
        return 0

    # Size check (Write only — Edit doesn't have a content field)
    if tool_name == "Write":
        content = tool_input.get("content", "")
        if content:  # content was non-empty
            try:
                actual_size = os.path.getsize(fs_path)
            except OSError:
                return 0
            if actual_size == 0:
                expected_size = len(content.encode("utf-8"))
                template = messages.get("empty_file", "")
                try:
                    msg = template.format(
                        file_path=file_path,
                        expected_size=expected_size,
                    )
                except (KeyError, IndexError):
                    msg = template
                emit_warning(msg)
                log_fire(
                    hook_name="silent-file-verifier",
                    action="warn-empty",
                    project=os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd", ""),
                    detail=f"tool={tool_name} file={file_path} expected_bytes={expected_size}",
                    session_id=payload.get("session_id", ""),
                )
                return 0

    # Success case: silent (no stdout output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
