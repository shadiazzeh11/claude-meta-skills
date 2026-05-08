#!/usr/bin/env python3
"""
construction-gate hook for Claude Code.

PreToolUse hook on Write. Blocks writes to protected paths (dependency
directories, lock files, sensitive config). Narrow scope: protected
paths only — no TODO/placeholder check (delegated to specialized
ecosystem tools like danielmiessler/PAI).

Patterns are configurable via rules.json next to the hook script.
Defaults cover common cases (node_modules/, .git/, .env, lock files).

Exit codes:
  0  - Allow the write (no protected pattern matched, or hook can't run)
  2  - Block the write with stderr feedback
"""
import json
import sys
import os
import re
from pathlib import Path


DEFAULT_PATTERNS = [
    r"node_modules/",
    r"\.git/",
    r"\.env(?:\.|$)",
    r"package-lock\.json$",
    r"yarn\.lock$",
    r"bun\.lockb$",
    r"\.claude/settings\.json$",
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
        "punitive": "BLOCKED: Write to protected path {file_path} matching pattern '{pattern}'.",
    }
    if not messages_path.exists():
        return fallback
    try:
        with open(messages_path) as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        return fallback


def find_matching_pattern(file_path, patterns):
    """Return the first pattern that matches file_path, or None."""
    for pattern in patterns:
        try:
            if re.search(pattern, file_path):
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
    file_path = tool_input.get("file_path", "")

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

    matched = find_matching_pattern(file_path, valid_patterns)
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
    return 2


if __name__ == "__main__":
    sys.exit(main())
