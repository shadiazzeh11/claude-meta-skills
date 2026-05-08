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
    file_path = tool_input.get("file_path", "")

    if not file_path:
        return 0

    messages = load_messages()
    default_version = messages.get("default", "constructive")

    # Existence check
    if not os.path.exists(file_path):
        if default_version == "constructive":
            template = messages.get("missing_file", "")
        else:
            template = messages.get("missing_file_punitive", "")
        try:
            msg = template.format(file_path=file_path, tool_name=tool_name)
        except (KeyError, IndexError):
            msg = template
        emit_warning(msg)
        return 0

    # Size check (Write only — Edit doesn't have a content field)
    if tool_name == "Write":
        content = tool_input.get("content", "")
        if content:  # content was non-empty
            try:
                actual_size = os.path.getsize(file_path)
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
                return 0

    # Success case: silent (no stdout output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
