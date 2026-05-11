#!/usr/bin/env python3
"""
construction-gate hook for Claude Code.

PreToolUse hook on Write/Edit/MultiEdit/NotebookEdit. Blocks file
modifications to protected paths (dependency directories, lock files,
sensitive config). Narrow scope: protected paths only — no
TODO/placeholder check (delegated to specialized ecosystem tools like
danielmiessler/PAI).

Patterns are configurable via rules.json next to the hook script.
Defaults cover common cases (node_modules/, .git/, .env, lock files).

Exit codes:
  0  - Allow the modification (no protected pattern matched, or hook can't run)
  2  - Block the modification with stderr feedback
"""
import json
import sys
import os
import re
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
        # POSIX atomic append for writes < PIPE_BUF (4096 bytes).
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


DEFAULT_PATTERNS = [
    r"(?:^|/)node_modules/",
    r"(?:^|/)\.git/",
    r"(?:^|/)\.env(?:\.[^/]+)?$",
    r"(?:^|/)package-lock\.json$",
    r"(?:^|/)yarn\.lock$",
    r"(?:^|/)bun\.lockb$",
    r"(?:^|/)\.claude/settings\.json$",
    r"(?:^|/)Cargo\.lock$",
    r"(?:^|/)Gemfile\.lock$",
    r"(?:^|/)poetry\.lock$",
    r"(?:^|/)uv\.lock$",
    r"(?:^|/)pnpm-lock\.yaml$",
    r"(?:^|/)Pipfile\.lock$",
    r"(?:^|/)\.claude/settings\.local\.json$",
    r"(?:^|/)\.claude/hooks/",
]


def load_rules():
    """Load protected path patterns from rules.json next to the script."""
    rules_path = Path(__file__).parent / "rules.json"
    if not rules_path.exists():
        return DEFAULT_PATTERNS
    try:
        with open(rules_path) as f:
            data = json.load(f)
        patterns = data.get("protected_patterns", DEFAULT_PATTERNS)
        if not isinstance(patterns, list):
            return DEFAULT_PATTERNS
        return [str(p) for p in patterns]
    except (IOError, json.JSONDecodeError):
        return DEFAULT_PATTERNS


def load_messages():
    """Load template messages from messages.json next to the script."""
    script_dir = Path(__file__).parent
    messages_path = script_dir / "messages.json"
    fallback = {
        "default": "constructive",
        "constructive": "This file path matches a protected pattern: '{pattern}'. Protected paths typically contain dependencies, version control data, or lock files that shouldn't be modified directly.",
        "punitive": "BLOCKED: file modification of protected path {file_path} matching pattern '{pattern}'.",
    }
    if not messages_path.exists():
        return fallback
    try:
        with open(messages_path) as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return fallback


def _append_unique(items, value):
    """Append a non-empty string once, preserving order."""
    if value and value not in items:
        items.append(value)


def _normalize_separators(path):
    """Normalize path separators for regex matching."""
    return str(path).replace("\\", "/")


def _is_relative_to(path, base):
    """Return True when path is inside base, using lexical absolute paths."""
    try:
        common = os.path.commonpath([path, base])
    except ValueError:
        return False
    return common == base


def path_variants(file_path, cwd=None, project_dir=None):
    """Return tool-provided and cwd/project-resolved path variants.

    Claude Code usually sends absolute file paths, but relative payload paths
    can occur when a session is working from a subdirectory. Protected-path
    matching must therefore consider the raw path and the path resolved against
    the payload cwd / project root without requiring the target to exist.
    """
    variants = []
    if not file_path:
        return variants

    normalized = _normalize_separators(file_path)
    raw_is_absolute = os.path.isabs(normalized)
    if not raw_is_absolute:
        _append_unique(variants, file_path)
        _append_unique(variants, normalized)

    project_abs = None
    if project_dir:
        project_abs = _normalize_separators(os.path.abspath(_normalize_separators(project_dir)))

    if raw_is_absolute:
        resolved_abs = _normalize_separators(os.path.abspath(normalized))
    else:
        base = cwd or project_dir or ""
        if base:
            base_normalized = _normalize_separators(base)
            resolved_abs = _normalize_separators(
                os.path.abspath(os.path.join(base_normalized, normalized))
            )
        else:
            resolved_abs = _normalize_separators(os.path.abspath(normalized))

    if project_abs and _is_relative_to(resolved_abs, project_abs):
        rel = os.path.relpath(resolved_abs, project_abs)
        if rel != ".":
            _append_unique(variants, _normalize_separators(rel))
    else:
        # Without a trusted project root, the cwd-resolved absolute path is the
        # best available signal. With a project root, only match absolute paths
        # outside the project to avoid false positives from parent directories
        # named like protected paths.
        _append_unique(variants, resolved_abs)

    return variants


def find_matching_pattern(file_path, patterns, cwd=None, project_dir=None):
    """Return the first pattern that matches file_path variants, or None."""
    for pattern in patterns:
        try:
            compiled = re.compile(pattern)
            if any(compiled.search(path) for path in path_variants(file_path, cwd, project_dir)):
                return pattern
        except re.error:
            # Invalid regex; skip this pattern silently
            continue
    return None


def main():
    # Read JSON from stdin. Malformed → exit 0 (don't block on hook errors).
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_input = payload.get("tool_input", {})
    # NotebookEdit payloads carry the path under notebook_path, not file_path.
    file_path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""

    if not file_path:
        return 0

    patterns = load_rules()

    # Validate patterns once; skip invalid ones rather than crashing.
    valid_patterns = []
    for pattern in patterns:
        try:
            re.compile(pattern)
            valid_patterns.append(pattern)
        except re.error:
            continue

    if not valid_patterns:
        # All patterns invalid; can't enforce. Allow write rather than block on hook error.
        return 0

    cwd = payload.get("cwd") or ""
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    matched = find_matching_pattern(file_path, valid_patterns, cwd=cwd, project_dir=project_dir)
    if matched is None:
        return 0

    # Path matches a protected pattern. Block with feedback.
    messages = load_messages()
    default_version = messages.get("default", "constructive")
    template = messages.get(default_version, "")
    try:
        message = template.format(file_path=file_path, pattern=matched)
    except (KeyError, IndexError):
        message = template

    sys.stderr.write(message + "\n")

    log_fire(
        hook_name="construction-gate",
        action="block",
        project=os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd", ""),
        detail=f"pattern={matched} file={file_path}",
        session_id=payload.get("session_id", ""),
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
