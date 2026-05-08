#!/usr/bin/env python3
"""
completion-verifier hook for Claude Code.

Stop hook. When Claude tries to finish responding, runs the project's
test command and blocks completion if tests are failing. Addresses the
#1 community complaint: Claude saying "done" when it isn't.

Exit semantics:
  - Anti-loop: if stop_hook_active is true, exit 0 immediately (mandatory).
  - No project type: exit 0 (allow stop).
  - Transcript shows no Write/Edit usage: exit 0 (exploration session).
  - Test command not installed: exit 0 with additionalContext warning.
  - Test command times out: exit 0 with additionalContext warning.
  - Tests pass: exit 0 (allow stop).
  - Tests fail: exit 0 with JSON {"decision": "block", "reason": ...}
    (Stop hook blocking is via JSON, not exit 2.)

Output format: when blocking, emits JSON on stdout with decision and reason.
When warning, emits JSON with hookSpecificOutput.additionalContext.
"""
import json
import sys
import os
import subprocess
from pathlib import Path

TIMEOUT_SECS = int(os.environ.get("COMPLETION_VERIFIER_TIMEOUT_SECS", "30"))
LAST_N_LINES = 50

# Project-type detection: ordered list of (config_file, test_command).
# First match wins. Python uses unittest (stdlib) instead of pytest for
# universal availability.
PROJECT_TYPES = [
    ("package.json", ["npm", "test"]),
    ("Cargo.toml", ["cargo", "test"]),
    ("pyproject.toml", ["python3", "-m", "unittest", "discover", "-v"]),
    ("setup.py", ["python3", "-m", "unittest", "discover", "-v"]),
    ("go.mod", ["go", "test", "./..."]),
    ("Makefile", ["make", "test"]),
]


def detect_project_type(cwd):
    """Return (config_file, test_command) or (None, None)."""
    for config, cmd in PROJECT_TYPES:
        if (Path(cwd) / config).is_file():
            return config, cmd
    return None, None


def transcript_has_writes(transcript_path):
    """
    Inspect the JSONL transcript for Write or Edit tool_use entries.
    Returns True if writes found, False if confirmed no writes,
    None if transcript is unreadable (caller decides default behavior).
    """
    if not transcript_path or not os.path.exists(transcript_path):
        return None
    try:
        with open(transcript_path, "r", errors="replace") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                # Transcript format: each line is a message; content can be
                # a list of blocks including tool_use entries.
                msg = entry.get("message") or entry
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_use" and block.get("name") in ("Write", "Edit"):
                            return True
        return False
    except (IOError, OSError):
        return None


def load_messages():
    """Load template messages from messages.json next to this script."""
    script_dir = Path(__file__).parent
    messages_path = script_dir / "messages.json"
    fallback = {
        "default": "constructive",
        "constructive": "Tests are failing in the current project. Output:\n{output}\nAddress the failures or note unrelated.",
        "punitive": "Tests failing. Fix tests before completing.\n{output}",
        "timeout": "Test command timed out after {timeout}s. Cannot verify completion; consider running tests manually.",
        "command_not_found": "Test command '{cmd}' not found. Skipping completion check; ensure the test runner is installed.",
    }
    if not messages_path.exists():
        return fallback
    try:
        with open(messages_path) as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return fallback


def emit_warning(message):
    """Emit a non-blocking PostToolUse-style additionalContext warning."""
    output = {
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": message,
        }
    }
    print(json.dumps(output))


def emit_block(reason):
    """Emit a Stop-hook block decision with reason."""
    output = {
        "decision": "block",
        "reason": reason,
    }
    print(json.dumps(output))


def main():
    # Read JSON from stdin. Malformed → exit 0 (don't block on hook errors).
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    # MANDATORY anti-loop check (issues #3573, #10205). If Claude is already
    # in a forced-continuation state, allow it to stop.
    if payload.get("stop_hook_active") is True:
        return 0

    cwd = payload.get("cwd") or os.getcwd()
    transcript_path = payload.get("transcript_path", "")

    # Project type detection
    config, cmd = detect_project_type(cwd)
    if config is None:
        return 0  # No recognizable project; allow stop

    # If transcript readable AND no Write/Edit calls observed → exploration
    # session, allow stop. If transcript unreadable, accept the false-positive
    # risk and run tests anyway (per spec).
    writes_check = transcript_has_writes(transcript_path)
    if writes_check is False:
        return 0

    messages = load_messages()
    default_version = messages.get("default", "constructive")

    # Run the test command
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            timeout=TIMEOUT_SECS,
            capture_output=True,
            text=True,
        )
    except subprocess.TimeoutExpired:
        timeout_template = messages.get("timeout", "")
        try:
            msg = timeout_template.format(timeout=TIMEOUT_SECS)
        except (KeyError, IndexError):
            msg = timeout_template
        emit_warning(msg)
        return 0
    except FileNotFoundError:
        notfound_template = messages.get("command_not_found", "")
        try:
            msg = notfound_template.format(cmd=" ".join(cmd))
        except (KeyError, IndexError):
            msg = notfound_template
        emit_warning(msg)
        return 0
    except (OSError, IOError):
        return 0

    # Tests passed → allow stop
    if result.returncode == 0:
        return 0

    # Tests failed → block with last N lines of output
    combined = (result.stdout or "") + (result.stderr or "")
    lines = combined.split("\n")
    last_lines = "\n".join(lines[-LAST_N_LINES:])

    template = messages.get(default_version, "")
    try:
        message = template.format(output=last_lines)
    except (KeyError, IndexError):
        message = template + "\n\n" + last_lines

    emit_block(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
