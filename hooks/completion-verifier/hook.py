#!/usr/bin/env python3
"""
completion-verifier hook for Claude Code.

Stop hook. When Claude tries to finish responding, runs the project's
test command and blocks completion if tests are failing. Addresses the
#1 community complaint: Claude saying "done" when it isn't.

Exit semantics:
  - Anti-loop: if stop_hook_active is true, exit 0 immediately (mandatory).
  - No project type: exit 0 (allow stop).
  - Transcript shows no file-modifying tool usage: exit 0 (exploration session).
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

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python <3.11 fallback
    tomllib = None


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


def parse_positive_int(value, default):
    """Parse a positive integer env setting, falling back on invalid input."""
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed <= 0:
        return default
    return parsed


TIMEOUT_SECS = parse_positive_int(os.environ.get("COMPLETION_VERIFIER_TIMEOUT_SECS", "30"), 30)
LAST_N_LINES = 50

# Project-type detection: ordered list of (config_file, test_command).
# First match wins. Python projects default to unittest, but pytest-style
# pyproject repos prefer an already-installed local pytest runner so uv/venv
# projects are verified in the same environment their own tests use.
PYTHON_UNITTEST_CMD = ["python3", "-m", "unittest", "discover", "-v"]
PROJECT_TYPES = [
    ("package.json", ["npm", "test"]),
    ("Cargo.toml", ["cargo", "test"]),
    ("pyproject.toml", None),
    ("setup.py", None),
    ("go.mod", ["go", "test", "./..."]),
    ("Makefile", ["make", "test"]),
]


def is_git_root(path):
    """True if path contains a .git directory or file (worktree)."""
    if not path:
        return False
    return (Path(path) / ".git").exists()


def _is_relative_to(path, base):
    """Return True when path is inside base, using lexical absolute paths."""
    try:
        common = os.path.commonpath([str(path), str(base)])
    except ValueError:
        return False
    return common == str(base)


def resolve_project_root(cwd):
    """
    Return the root to inspect for project config files.

    Claude Code usually sets $CLAUDE_PROJECT_DIR, which is the trusted upper
    bound for parent discovery. Within that bound, walk upward from cwd until
    a project config is found or the nearest git root is reached. Without the
    env var, apply the same search from cwd through its parents. This handles
    subdirectory Stop events without leaking into unrelated parent repos.
    """
    root = Path(cwd)
    try:
        root = root.expanduser().resolve(strict=False)
    except OSError:
        root = root.expanduser()

    env_root = None
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir and os.path.isdir(project_dir):
        try:
            env_root = Path(project_dir).expanduser().resolve(strict=False)
        except OSError:
            env_root = Path(project_dir).expanduser()

    if env_root is not None:
        if _is_relative_to(root, env_root):
            candidates = []
            current = root
            while True:
                candidates.append(current)
                if current == env_root:
                    break
                current = current.parent
        else:
            candidates = [env_root]
    else:
        candidates = [root] + list(root.parents)

    config_names = [config for config, _cmd in PROJECT_TYPES]
    for candidate in candidates:
        if any((candidate / config).is_file() for config in config_names):
            return str(candidate)
        if is_git_root(candidate):
            return str(candidate)

    return str(env_root or root)


def project_uses_pytest(cwd):
    """Return True when Python project metadata points at pytest."""
    root = Path(cwd)
    if (root / "pytest.ini").is_file():
        return True

    pyproject = root / "pyproject.toml"
    if pyproject.is_file() and tomllib is not None:
        try:
            data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            data = {}
        if ((data.get("tool") or {}).get("pytest")) is not None:
            return True
        project = data.get("project") or {}
        dependencies = list(project.get("dependencies") or [])
        optional = project.get("optional-dependencies") or {}
        for values in optional.values():
            dependencies.extend(values or [])
        if any(str(dep).lower().split(";", 1)[0].strip().startswith("pytest") for dep in dependencies):
            return True

    for config_name in ("pyproject.toml", "setup.cfg", "tox.ini"):
        path = root / config_name
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace").lower()
        except OSError:
            continue
        if "[tool.pytest" in text or "pytest" in text:
            return True
    return False


def candidate_local_pythons(cwd):
    """Yield local virtualenv Python executables in preference order."""
    root = Path(cwd)
    candidates = [
        root / ".venv" / "bin" / "python",
        root / ".venv" / "bin" / "python3",
        root / "venv" / "bin" / "python",
        root / "venv" / "bin" / "python3",
        root / ".venv" / "Scripts" / "python.exe",
        root / "venv" / "Scripts" / "python.exe",
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            yield str(candidate)


def python_has_module(python_exe, module):
    """Best-effort check that `python_exe -m module` can import its module."""
    try:
        result = subprocess.run(
            [
                python_exe,
                "-c",
                (
                    "import importlib.util, sys; "
                    "sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)"
                ),
                module,
            ],
            timeout=2,
            capture_output=True,
            text=True,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False
    return result.returncode == 0


def python_test_command(cwd, config):
    """Select a Python test command, or None when pytest is declared but unavailable."""
    if project_uses_pytest(cwd):
        for python_exe in candidate_local_pythons(cwd):
            if python_has_module(python_exe, "pytest"):
                return [python_exe, "-m", "pytest"]
        if python_has_module("python3", "pytest"):
            return ["python3", "-m", "pytest"]
        return None
    return PYTHON_UNITTEST_CMD


def detect_project_type(cwd):
    """Return (project_root, config_file, test_command)."""
    project_root = resolve_project_root(cwd)
    for config, cmd in PROJECT_TYPES:
        if (Path(project_root) / config).is_file():
            if config in ("pyproject.toml", "setup.py"):
                return project_root, config, python_test_command(project_root, config)
            return project_root, config, cmd
    return project_root, None, None


FILE_MODIFYING_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")


def transcript_has_writes(transcript_path):
    """
    Inspect the JSONL transcript for file-modifying tool_use entries.
    Returns:
      True  - at least one file-modifying tool found
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


def output_text(value):
    """Return subprocess output as text; TimeoutExpired can keep bytes despite text=True."""
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def last_output_lines(stdout, stderr, limit=LAST_N_LINES):
    """Return the last output lines from stdout/stderr without raising."""
    stdout_text = output_text(stdout)
    stderr_text = output_text(stderr)
    if stdout_text and stderr_text and not stdout_text.endswith(("\n", "\r")):
        combined = stdout_text + "\n" + stderr_text
    else:
        combined = stdout_text + stderr_text
    if not combined:
        return ""
    return "\n".join(combined.splitlines()[-limit:])


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
    project_root, config, cmd = detect_project_type(cwd)
    if config is None:
        return 0  # No recognizable project; allow stop
    messages = load_messages()
    if cmd is None:
        notfound_template = messages.get("command_not_found", "")
        try:
            msg = notfound_template.format(cmd="pytest")
        except (KeyError, IndexError):
            msg = "Test command 'pytest' not found. Skipping completion check; ensure pytest is installed."
        emit_warning(msg)
        log_fire(
            hook_name="completion-verifier",
            action="warn-cmd-missing",
            project=project_root,
            detail=f"project_type={config} cmd=pytest",
            session_id=payload.get("session_id", ""),
        )
        return 0

    # If transcript readable AND no file-modifying tools were observed, this
    # was an exploration session; allow stop. If transcript unreadable, accept
    # the false-positive risk and run tests anyway (per spec).
    writes_check = transcript_has_writes(transcript_path)
    if writes_check is False:
        return 0

    default_version = messages.get("default", "constructive")

    # Run the test command
    try:
        result = subprocess.run(
            cmd,
            cwd=project_root,
            timeout=TIMEOUT_SECS,
            capture_output=True,
            text=True,
        )
    except subprocess.TimeoutExpired as exc:
        timeout_template = messages.get("timeout", "")
        try:
            msg = timeout_template.format(timeout=TIMEOUT_SECS)
        except (KeyError, IndexError):
            msg = timeout_template
        partial_output = last_output_lines(
            exc.stdout if exc.stdout is not None else exc.output,
            exc.stderr,
        )
        if partial_output:
            msg = msg + "\n\nPartial output before timeout:\n\n" + partial_output
        emit_warning(msg)
        log_fire(
            hook_name="completion-verifier",
            action="warn-timeout",
            project=project_root,
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
            project=project_root,
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
    last_lines = last_output_lines(result.stdout, result.stderr)

    template = messages.get(default_version, "")
    try:
        message = template.format(output=last_lines)
    except (KeyError, IndexError):
        message = template + "\n\n" + last_lines

    emit_block(message)
    log_fire(
        hook_name="completion-verifier",
        action="block",
        project=project_root,
        detail=f"project_type={config} test_exit_code={result.returncode}",
        session_id=payload.get("session_id", ""),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
