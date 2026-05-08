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
from datetime import datetime, timezone


def log_fire(hook_name, action, project, detail, session_id):
    """Append one JSON line to ~/.claude/meta-skills-log.jsonl. Best-effort; never raises.
    Detail is metadata only — no file content, no diff snippets, no test output."""
    try:
        log_dir = Path.home() / ".claude"
        log_dir.mkdir(parents=True, exist_ok=True)
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
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    except Exception:
        pass


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


FILE_MODIFYING_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")


def transcript_has_writes(transcript_path):
    """
    Inspect the JSONL transcript for file-modifying tool_use entries.
    Returns:
      True  - at least one Write/Edit/MultiEdit/NotebookEdit found
      False - transcript was parseable but no file-modifying tools observed
      None  - transcript missing, IO error, or no valid JSON lines (unreadable)

    The None return signals the caller to fall back to running tests
    (per spec: accept the false-positive risk when transcript unreliable).
    """
    if not transcript_path or not os.path.exists(transcript_path):
        return None
    try:
        valid_lines = 0
        with open(transcript_path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                valid_lines += 1
                # Transcript format: each line is a message; content can be
                # a list of blocks including tool_use entries.
                msg = entry.get("message") or entry
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_use" and block.get("name") in FILE_MODIFYING_TOOLS:
                            return True
        # Parseable transcript with no file-modifying tools observed.
        if valid_lines > 0:
            return False
        # No valid JSON lines parsed — treat as unreadable.
        return None
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

    # If cwd doesn't exist, can't run tests. Allow stop with a distinct warning
    # (separate from command-not-found, which is a different failure mode).
    if not os.path.isdir(cwd):
        emit_warning(
            "Working directory '{cwd}' does not exist. Skipping completion check.".format(cwd=cwd)
        )
        log_fire(
            hook_name="completion-verifier",
            action="warn-cwd-missing",
            project=cwd,
            detail=f"cwd_missing={cwd}",
            session_id=payload.get("session_id", ""),
        )
        return 0

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
        log_fire(
            hook_name="completion-verifier",
            action="warn-timeout",
            project=cwd,
            detail=f"project_type={config} timeout={TIMEOUT_SECS}s",
            session_id=payload.get("session_id", ""),
        )
        return 0
    except FileNotFoundError:
        notfound_template = messages.get("command_not_found", "")
        try:
            msg = notfound_template.format(cmd=" ".join(cmd))
        except (KeyError, IndexError):
            msg = notfound_template
        emit_warning(msg)
        log_fire(
            hook_name="completion-verifier",
            action="warn-cmd-missing",
            project=cwd,
            detail=f"project_type={config} cmd={' '.join(cmd)}",
            session_id=payload.get("session_id", ""),
        )
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
    log_fire(
        hook_name="completion-verifier",
        action="block",
        project=cwd,
        detail=f"project_type={config} test_exit_code={result.returncode}",
        session_id=payload.get("session_id", ""),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
