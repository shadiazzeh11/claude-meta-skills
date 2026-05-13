#!/usr/bin/env python3
"""
edit-drift-detector hook for Claude Code.

PreToolUse hook on Edit. Compares the old_string Claude provides against
actual file content. If old_string doesn't match, blocks the edit and
provides correction context (closest matching content + suggestion).

Catches recall-vs-observed failures: drafting old_string from memory
when the file content has shifted or was misremembered.

Exit codes:
  0  - Allow the edit (old_string matches, whitespace-only difference,
       file doesn't exist, or hook can't run safely)
  2  - Block the edit (old_string mismatch detected) with stderr feedback
"""
import json
import sys
import os
import difflib
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


def normalize_trailing_whitespace(text):
    """Strip trailing whitespace from each line. Preserves leading whitespace."""
    return "\n".join(line.rstrip() for line in text.split("\n"))


def find_closest_match(file_lines, old_lines, min_ratio=0.6):
    """
    Find the contiguous block in file_lines most similar to old_lines.

    Slides a window of len(old_lines) across the file and computes
    SequenceMatcher ratio. Returns 1-indexed (start_line, end_line, ratio)
    if best match exceeds min_ratio, else (None, None, best_ratio).
    """
    if not old_lines or not file_lines:
        return None, None, 0.0

    block_size = len(old_lines)
    if block_size > len(file_lines):
        # File shorter than old_string; compare against entire file
        sm = difflib.SequenceMatcher(None, "\n".join(file_lines), "\n".join(old_lines))
        ratio = sm.ratio()
        if ratio >= min_ratio:
            return 1, len(file_lines), ratio
        return None, None, ratio

    best_ratio = 0.0
    best_start = None
    for i in range(len(file_lines) - block_size + 1):
        window = file_lines[i:i + block_size]
        sm = difflib.SequenceMatcher(None, "\n".join(window), "\n".join(old_lines))
        ratio = sm.ratio()
        if ratio > best_ratio:
            best_ratio = ratio
            best_start = i

    if best_ratio < min_ratio or best_start is None:
        return None, None, best_ratio

    return best_start + 1, best_start + block_size, best_ratio


def resolve_file_path(file_path, payload):
    """Resolve a tool_input file_path against the payload's cwd when relative.

    Absolute paths are returned as-is. Relative paths are joined onto
    payload['cwd'] when that key is present and points to an existing
    directory; otherwise the original (relative) path is returned and
    will resolve against the hook process's cwd. The resolved path is
    intended for filesystem operations only; the original file_path is
    preserved for user-facing messages and log details.
    """
    if not file_path:
        return file_path
    if os.path.isabs(file_path):
        return file_path
    cwd = payload.get("cwd", "")
    if cwd and os.path.isdir(cwd):
        return os.path.join(cwd, file_path)
    return file_path


DEFAULT_PROTECTED_PATTERNS = [
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


def load_protected_patterns():
    """Load construction-gate protected path patterns without importing that hook."""
    rules_path = Path(__file__).parent.parent / "construction-gate" / "rules.json"
    if not rules_path.exists():
        return DEFAULT_PROTECTED_PATTERNS
    try:
        with open(rules_path) as f:
            data = json.load(f)
        patterns = data.get("protected_patterns", DEFAULT_PROTECTED_PATTERNS)
        if not isinstance(patterns, list):
            return DEFAULT_PROTECTED_PATTERNS
        return [str(p) for p in patterns]
    except (IOError, json.JSONDecodeError):
        return DEFAULT_PROTECTED_PATTERNS


def path_variants(file_path):
    """Return tool-provided path variants with normalized separators."""
    variants = []
    if not file_path:
        return variants
    variants.append(file_path)
    normalized = file_path.replace("\\", "/")
    if normalized != file_path:
        variants.append(normalized)
    return variants


def is_protected_path(file_path):
    """True when construction-gate should own feedback for this path.

    edit-drift-detector may include nearby file content in its correction
    message. For protected paths, avoid reading the file at all; construction-gate
    owns metadata-only blocking for that surface. Match only the tool-provided
    path, not the cwd-resolved filesystem path, so a normal relative edit inside
    a directory named ".env.project" is not skipped.
    """
    for pattern in load_protected_patterns():
        try:
            compiled = re.compile(pattern)
        except re.error:
            continue
        if any(compiled.search(path) for path in path_variants(file_path)):
            return True
    return False


def load_messages():
    """Load message templates from messages.json next to this script."""
    script_dir = Path(__file__).parent
    messages_path = script_dir / "messages.json"
    if not messages_path.exists():
        # Fallback if messages.json missing or unreadable
        return {
            "default": "constructive",
            "constructive": (
                "The old_str doesn't match the file at lines {line_range}. "
                "Re-read the file and retry."
            ),
            "no_close_match": (
                "The old_str doesn't appear in {file_path} and no similar "
                "content was found. Re-read the file with Read."
            ),
        }
    try:
        with open(messages_path) as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return {
            "default": "constructive",
            "constructive": "The old_str doesn't match. Re-read the file.",
            "no_close_match": "No match found. Re-read the file.",
        }


def main():
    # Read JSON from stdin. Malformed input → exit 0 (don't block on hook errors).
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
    old_string = tool_input.get("old_string", "")

    if not file_path or not old_string:
        return 0

    fs_path = resolve_file_path(file_path, payload)

    if is_protected_path(file_path):
        return 0

    # File must exist for comparison; otherwise let Edit's error handling catch it.
    if not os.path.exists(fs_path):
        return 0
    if not os.path.isfile(fs_path):
        return 0

    # Read the file content.
    try:
        with open(fs_path, "r", errors="replace") as f:
            file_content = f.read()
    except (IOError, OSError):
        return 0

    # Exact substring match → allow.
    if old_string in file_content:
        return 0

    # Whitespace-normalized match → allow (design decision: trailing-whitespace
    # mismatches are below recall-drift threshold; see README).
    normalized_file = normalize_trailing_whitespace(file_content)
    normalized_old = normalize_trailing_whitespace(old_string)
    if normalized_old in normalized_file:
        return 0

    # No match. Find closest fuzzy match for correction context.
    file_lines = file_content.splitlines()
    old_lines = old_string.splitlines()
    start_line, end_line, ratio = find_closest_match(file_lines, old_lines)

    messages = load_messages()
    default_version = messages.get("default", "constructive")
    template = messages.get(default_version, "")

    if start_line is not None:
        # Show actual content at closest match location.
        context_start = max(0, start_line - 1)
        context_end = min(len(file_lines), end_line)
        actual_content = "\n".join(file_lines[context_start:context_end])
        line_range = f"{start_line}-{end_line}" if start_line != end_line else str(start_line)
        try:
            message = template.format(
                file_path=file_path,
                line_range=line_range,
                actual_content=actual_content,
                similarity="{:.0%}".format(ratio),
            )
        except (KeyError, IndexError):
            message = template
        log_action = "block-fuzzy"
        log_detail = f"file={file_path} lines={line_range} similarity={ratio:.2f}"
    else:
        no_match_template = messages.get("no_close_match", "")
        try:
            message = no_match_template.format(file_path=file_path)
        except (KeyError, IndexError):
            message = no_match_template
        log_action = "block-no-match"
        log_detail = f"file={file_path} best_ratio={ratio:.2f}"

    sys.stderr.write(message + "\n")
    log_fire(
        hook_name="edit-drift-detector",
        action=log_action,
        project=os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd", ""),
        detail=log_detail,
        session_id=payload.get("session_id", ""),
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
