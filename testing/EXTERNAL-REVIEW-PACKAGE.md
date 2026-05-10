# External Review Package — claude-meta-skills

> **Audit context.** This document is generated for ChatGPT to review the claude-meta-skills project end-to-end without access to the GitHub repository (which is currently PRIVATE) or to the build conversation history. Everything required to evaluate the project is inlined below: full source of all 5 hooks, the validation harness, validation results, architecture decisions, ecosystem context, known limitations, the complete test inventory, key research sources, open questions, and the logging system.
>
> **Goal of this review:** find problems. Logic bugs, security holes, design flaws, ecosystem-positioning blind spots, false-confidence claims, contradictions between docs and code, and anything that would embarrass us in a public audit.

> **Historical snapshot warning.** This package is a stale external-review snapshot from an earlier phase. It is retained for audit history, not as the current source of truth. For current validation counts, CI status, and dogfood evidence, start with `README.md` and `testing/DOGFOOD-BASELINE.md`.

---

## Section 1: Project overview

**claude-meta-skills** is a focused Claude Code hooks suite with measured false-positive rates. It provides five small hooks that each catch a documented Claude Code failure mode at a different point in the tool-call lifecycle, plus a generic validation harness usable for any Claude Code hook (not just ours).

The architecture covers Blake Crosley's four-layer hook framework: **Prevention** (PreToolUse), **Validation** (PostToolUse), **Quality Gating** (Stop), and **Context Injection** (PreCompact). Each hook ships with its own Python source (~150–350 lines, stdlib only), per-hook README, baseline validation results, configurable `messages.json` (constructive vs punitive variants), and where applicable a `rules.json` for protected-pattern lists or static reminders.

**Repository:** `github.com/shadiazzeh11/claude-meta-skills` — currently **PRIVATE**. The clone instructions in README.md will not work for an external reviewer; this document is the canonical source of truth for the audit.

**Authors:** Shadi AL Azzeh and Caleb Mukasa, joint MIT copyright 2026. Co-authored throughout by Claude Opus 4.7 (1M context). Built across five build phases (foundation, two hook batches, polish, packaging+logging) using a triangle workflow: Caleb (decision authority), CC (executor), chat-Claude (planner with broader research context).

**Validation status as of audit time:** 45/45 tests passing, 0 false positives, 0 false negatives, dogfood install live in the project's own repo, auto-logging operational. HEAD commit at audit: `c06dab1` (`feat: auto-logging + analysis script for self-deployment validation`).

**Pitch:** Claude Code hooks with measured false-positive rates. Five focused hooks covering edit verification, completion gating, file checks, write protection, and post-compaction context recovery. Each ships with a test suite. The validation harness works for any Claude Code hook, not just ours.

---

## Section 2: Complete hook source code

All five hooks are inlined below, in full, with no truncation. Each hook also has a `messages.json` (template strings with `constructive` and `punitive` A/B variants) and where applicable a `rules.json` (configurable patterns or reminders). A shared `log_fire()` function is duplicated inline in each hook (see Architecture Decision 4).

### 2.1 edit-drift-detector

**Event:** `PreToolUse:Edit` · **Layer:** Prevention · **Catches:** `old_string` doesn't match actual file content (recall-vs-observed failures).

#### `hooks/edit-drift-detector/hook.py` (204 lines)

```python
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

    # File must exist for comparison; otherwise let Edit's error handling catch it.
    if not os.path.exists(file_path):
        return 0
    if not os.path.isfile(file_path):
        return 0

    # Read the file content.
    try:
        with open(file_path, "r", errors="replace") as f:
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
```

#### `hooks/edit-drift-detector/messages.json`

```json
{
  "default": "constructive",

  "_comment_versions": "Two feedback message versions for A/B testing in Phase 2+. The hook uses the version named in 'default' field. Switch by changing 'default' to 'punitive' or 'constructive'.",

  "constructive": "The old_str doesn't match the file at lines {line_range} (closest match similarity: {similarity}). Here's what the file actually contains at that location:\n\n{actual_content}\n\nThe mismatch likely means the file changed since you last read it, or the old_str was drafted from memory rather than fresh read. Re-read the file with Read at offset {line_range}, then retry the Edit with the exact string from the file.",

  "punitive": "ERROR: BLOCKED. The old_str does not match file content at {file_path}. You failed to verify before editing. Re-read the file before retrying.",

  "no_close_match": "The old_str doesn't appear in {file_path} and no similar content was found in the file. The file may have been completely rewritten since the last read, or the old_str may be from a different file. Re-read the file with Read to see current content."
}
```

(no `rules.json` for this hook)

---

### 2.2 construction-gate

**Event:** `PreToolUse:Write` · **Layer:** Prevention · **Catches:** Writes to protected paths (dependency dirs, lock files, env files, .git internals).

#### `hooks/construction-gate/hook.py` (162 lines)

```python
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
        # POSIX atomic append for writes < PIPE_BUF (4096 bytes).
        fd = os.open(str(log_dir / "meta-skills-log.jsonl"),
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    except Exception:
        pass


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
```

#### `hooks/construction-gate/messages.json`

```json
{
  "default": "constructive",

  "_comment_versions": "A/B testing variants for Phase 4+. Switch by changing 'default' to 'punitive' or 'constructive'.",

  "constructive": "This file path matches a protected pattern: '{pattern}'. Protected paths typically contain dependencies, version control data, or lock files that shouldn't be modified directly by Claude. If this write is intentional and you understand the implications, ask the user to temporarily disable the construction-gate hook or add an exception to rules.json.",

  "punitive": "BLOCKED: Write to protected path {file_path} matching pattern '{pattern}'."
}
```

#### `hooks/construction-gate/rules.json`

```json
{
  "_description": "Patterns matched against the full file path (regex syntax). Add project-specific patterns as needed. Examples: 'src/generated/' to protect generated code, 'config/secrets/' for sensitive config.",
  "protected_patterns": [
    "node_modules/",
    "\\.git/",
    "\\.env(?:\\.|$)",
    "package-lock\\.json$",
    "yarn\\.lock$",
    "bun\\.lockb$",
    "\\.claude/settings\\.json$",
    "Cargo\\.lock$",
    "Gemfile\\.lock$",
    "poetry\\.lock$",
    "uv\\.lock$"
  ]
}
```

---

### 2.3 silent-file-verifier

**Event:** `PostToolUse:Write|Edit|MultiEdit|NotebookEdit` · **Layer:** Validation · **Catches:** Ghost files (Write reports success, file missing or 0 bytes when content was non-empty).

#### `hooks/silent-file-verifier/hook.py` (151 lines)

```python
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
```

#### `hooks/silent-file-verifier/messages.json`

```json
{
  "default": "constructive",

  "_comment_versions": "A/B testing variants for Phase 2+. Switch via 'default'.",

  "missing_file": "The {tool_name} reported success but {file_path} doesn't exist on disk. This is sometimes a path-resolution issue or a permissions problem. Verify the path with `ls`, then retry with the confirmed absolute path.",

  "missing_file_punitive": "WARNING: File {file_path} does not exist after {tool_name} operation reported success.",

  "empty_file": "The Write of {file_path} reported success but the file is 0 bytes (the content provided was non-empty, expected ~{expected_size} bytes). Verify the content was written and retry the Write if needed."
}
```

(no `rules.json` for this hook)

---

### 2.4 completion-verifier

**Event:** `Stop` · **Layer:** Quality Gating · **Catches:** Tests failing when Claude attempts to finish responding.

#### `hooks/completion-verifier/hook.py` (280 lines)

```python
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
```

#### `hooks/completion-verifier/messages.json`

```json
{
  "default": "constructive",

  "_comment_versions": "Two feedback message versions for A/B testing in Phase 2+. Switch by changing 'default' to 'punitive' or 'constructive'.",

  "constructive": "Tests are failing in the current project. Here's the relevant output:\n\n{output}\n\nAddress the failing tests, or if the failures are unrelated to your current task, note that explicitly in your response so the user can verify.",

  "punitive": "Tests failing. Fix tests before completing.\n\n{output}",

  "timeout": "Test command timed out after {timeout}s. Completion check could not finish; consider running tests manually before declaring done.",

  "command_not_found": "Test command '{cmd}' not found in PATH. Skipping completion check; install the test runner or define a Makefile target if you want this hook to verify completion."
}
```

(no `rules.json` for this hook)

---

### 2.5 context-recovery

**Event:** `PreCompact` · **Layer:** Context Injection · **Catches:** Session context lost during context-window compaction.

#### `hooks/context-recovery/hook.py` (352 lines)

```python
#!/usr/bin/env python3
"""
context-recovery hook for Claude Code.

PreCompact hook. Captures session context (git state + static reminders)
and writes a recovery section to CLAUDE.md before compaction. After
compaction, CLAUDE.md auto-reloads with the recovery context preserved.

Architecture: PreCompact + CLAUDE.md modification. Chosen because the
SessionStart:compact stdout-injection pathway is broken (issue #15174);
CLAUDE.md modification is the verified working path for post-compaction
context preservation. PostCompact event does not exist (issues #14258,
#40492, #32026 are all open feature requests).

Exit 0 always. PreCompact exit 2 has no blocking effect per Claude Code
docs; we don't try to block compaction.

macOS stdin bug (#38162) only affects async hooks. This hook must be
invoked synchronously (no "async": true in settings.json).
"""
import json
import sys
import os
import subprocess
import tempfile
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

# Delimiters: HTML comments. Standard markdown convention for invisible
# markers. The hook reads/writes raw file content, so the delimiter
# always works at the file level. Whether Claude sees them in rendered
# context is benign either way.
DELIMITER_START = "<!-- post-compact-recovery-start -->"
DELIMITER_END = "<!-- post-compact-recovery-end -->"

GIT_TIMEOUT_SECS = 5
# ~500 tokens; per Boris Cherny CLAUDE.md guidance to stay well under
# the 5000-token total budget.
RECOVERY_SECTION_MAX_CHARS = 2000


def resolve_claude_md_path(cwd):
    """
    Return the path where CLAUDE.md should be (whether or not it exists).
    Priority: $CLAUDE_PROJECT_DIR/CLAUDE.md > cwd/CLAUDE.md.
    """
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir and os.path.isdir(project_dir):
        return Path(project_dir) / "CLAUDE.md"
    if cwd:
        return Path(cwd) / "CLAUDE.md"
    return Path("CLAUDE.md")


def run_git_command(args, cwd):
    """
    Run a git command with timeout, returning stripped stdout or None on
    any failure (not a git repo, timeout, git missing, etc.).
    """
    try:
        result = subprocess.run(
            ["git"] + list(args),
            cwd=cwd,
            timeout=GIT_TIMEOUT_SECS,
            capture_output=True,
            text=True,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def is_git_root(path):
    """True if path contains a .git directory or file (worktree)."""
    if not path:
        return False
    return (Path(path) / ".git").exists()


def gather_git_context(cwd):
    """
    Return dict with branch, commits, modified_files (each may be None).

    Only collects git context if cwd OR $CLAUDE_PROJECT_DIR contains a
    .git directly. Avoids picking up unrelated parent-repo context when
    cwd is a subdirectory of a different git repo (e.g., test fixtures
    or scratch dirs inside home directories that happen to be repos).

    Real-world: Claude Code typically sets $CLAUDE_PROJECT_DIR to project
    root, which has .git, so this check passes. Subdirectory invocations
    without $CLAUDE_PROJECT_DIR fall through to skip (safe failure mode —
    surface no git context rather than the wrong context).
    """
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    git_cwd = None
    if project_dir and is_git_root(project_dir):
        git_cwd = project_dir
    elif is_git_root(cwd):
        git_cwd = cwd

    if git_cwd is None:
        return {"branch": None, "commits": None, "modified_files": None}

    return {
        "branch": run_git_command(["branch", "--show-current"], git_cwd),
        "commits": run_git_command(["log", "--oneline", "-5"], git_cwd),
        "modified_files": run_git_command(["diff", "--name-only", "HEAD"], git_cwd),
    }


def load_reminders():
    """Load static reminders from rules.json next to this script."""
    rules_path = Path(__file__).parent / "rules.json"
    if not rules_path.exists():
        return []
    try:
        with open(rules_path) as f:
            data = json.load(f)
        reminders = data.get("reminders", [])
        if not isinstance(reminders, list):
            return []
        return [str(r) for r in reminders]
    except (IOError, json.JSONDecodeError):
        return []


def render_section(git_context, reminders, custom_instructions, timestamp,
                   modified_files_limit=None):
    """
    Build the recovery section. If modified_files_limit is set, truncate
    the modified-files list to that many entries with a [truncated] marker.
    """
    lines = [
        DELIMITER_START,
        "## Session Recovery (auto-generated by context-recovery hook)",
        "",
    ]

    if git_context.get("branch"):
        lines.append(f"**Branch:** {git_context['branch']}")

    commits = git_context.get("commits")
    if commits:
        lines.append("")
        lines.append("**Recent commits:**")
        for line in commits.split("\n"):
            if line.strip():
                lines.append(f"- {line.strip()}")

    modified_files = git_context.get("modified_files")
    if modified_files:
        files = [f for f in modified_files.split("\n") if f.strip()]
        lines.append("")
        lines.append(f"**Modified files ({len(files)}):**")
        if modified_files_limit is not None and len(files) > modified_files_limit:
            for f in files[:modified_files_limit]:
                lines.append(f"- {f}")
            lines.append(f"- [truncated — {len(files) - modified_files_limit} more files]")
        else:
            for f in files:
                lines.append(f"- {f}")

    if reminders:
        lines.append("")
        lines.append("**Project reminders:**")
        for r in reminders:
            lines.append(f"- {r}")

    if custom_instructions:
        lines.append("")
        lines.append(f"**Custom instructions:** {custom_instructions}")

    lines.append("")
    lines.append(f"**Hook generated:** {timestamp}")
    lines.append(DELIMITER_END)

    return "\n".join(lines)


def build_recovery_section(git_context, reminders, custom_instructions):
    """Build recovery section, truncating modified-files list if over budget."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    full = render_section(git_context, reminders, custom_instructions, timestamp)
    if len(full) <= RECOVERY_SECTION_MAX_CHARS:
        return full

    # Over budget. Reduce modified-files list progressively.
    modified_files = git_context.get("modified_files")
    if not modified_files:
        # No modified-files list to truncate; section is over-budget for other reasons.
        # Best effort: return as-is; rare case.
        return full

    file_count = len([f for f in modified_files.split("\n") if f.strip()])
    # Binary-search-ish: try decreasing limits until under budget
    for limit in range(file_count - 1, -1, -1):
        truncated = render_section(
            git_context, reminders, custom_instructions, timestamp,
            modified_files_limit=limit,
        )
        if len(truncated) <= RECOVERY_SECTION_MAX_CHARS:
            return truncated
    # Even with 0 files shown, still over budget. Return as-is.
    return render_section(
        git_context, reminders, custom_instructions, timestamp,
        modified_files_limit=0,
    )


def merge_into_claude_md(existing_content, recovery_section):
    """
    Idempotent merge: if existing content has DELIMITER_START...DELIMITER_END,
    replace that block. Otherwise append at end.
    """
    if DELIMITER_START in existing_content and DELIMITER_END in existing_content:
        start_idx = existing_content.find(DELIMITER_START)
        end_idx = existing_content.find(DELIMITER_END, start_idx)
        if end_idx == -1:
            # Malformed (start without end); append cleanly
            return existing_content.rstrip() + "\n\n" + recovery_section + "\n"
        end_idx += len(DELIMITER_END)
        before = existing_content[:start_idx].rstrip()
        after = existing_content[end_idx:].lstrip()
        result = before + "\n\n" + recovery_section + "\n"
        if after:
            result += "\n" + after
        return result
    # No existing recovery block; append at end
    if existing_content and not existing_content.endswith("\n"):
        existing_content += "\n"
    return existing_content + "\n" + recovery_section + "\n"


def atomic_write(path, content):
    """Write content to path atomically via temp file + os.replace."""
    path = Path(path)
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        dir=str(parent),
        prefix=".context-recovery-",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main():
    # Read JSON from stdin. Malformed → exit 0 (don't interfere with compaction).
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id", "")
    custom_instructions = payload.get("custom_instructions", "") or ""

    claude_md_path = resolve_claude_md_path(cwd)
    project = os.environ.get("CLAUDE_PROJECT_DIR") or cwd

    git_context = gather_git_context(cwd)
    reminders = load_reminders()
    recovery_section = build_recovery_section(
        git_context, reminders, custom_instructions
    )

    branch = git_context.get("branch") or "no-git"
    modified = git_context.get("modified_files") or ""
    modified_count = len([f for f in modified.split("\n") if f.strip()]) if modified else 0
    detail_base = f"branch={branch} modified_files={modified_count}"

    # Read existing CLAUDE.md if present
    pre_existing = claude_md_path.exists()
    if pre_existing:
        try:
            with open(claude_md_path, "r", errors="replace") as f:
                existing_content = f.read()
        except (PermissionError, IOError, OSError) as e:
            log_fire(
                hook_name="context-recovery",
                action="skip-readonly",
                project=project,
                detail=f"path={claude_md_path} error={type(e).__name__}",
                session_id=session_id,
            )
            return 0  # Read-only or permission issue; skip silently
        new_content = merge_into_claude_md(existing_content, recovery_section)
    else:
        new_content = recovery_section + "\n"

    # Atomic write. If anything fails (read-only, full disk, etc.),
    # leave original CLAUDE.md untouched.
    try:
        atomic_write(claude_md_path, new_content)
    except (PermissionError, OSError, IOError) as e:
        log_fire(
            hook_name="context-recovery",
            action="skip-error",
            project=project,
            detail=f"path={claude_md_path} error={type(e).__name__}",
            session_id=session_id,
        )
        return 0

    log_fire(
        hook_name="context-recovery",
        action="modify" if pre_existing else "create",
        project=project,
        detail=detail_base,
        session_id=session_id,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

#### `hooks/context-recovery/messages.json`

```json
{
  "_purpose": "context-recovery is a PreCompact hook. Unlike PreToolUse/PostToolUse hooks, it does not send feedback to Claude via stderr or additionalContext — its 'output' IS the modified CLAUDE.md, which auto-reloads after compaction. messages.json is included for consistency with other hooks in this repo and to document the hook's purpose.",

  "description": "PreCompact hook that captures session context (git branch, recent commits, modified files, configurable static reminders) and writes a recovery section to CLAUDE.md before compaction. After compaction completes, CLAUDE.md auto-reloads with the recovery context preserved, so Claude regains awareness of pre-compaction session state.",

  "delimiter_choice": "HTML comments (<!-- post-compact-recovery-start --> ... <!-- post-compact-recovery-end -->). Standard markdown convention for invisible markers. The hook reads/writes raw file content; delimiter visibility in rendered context is irrelevant for the hook's mechanics."
}
```

#### `hooks/context-recovery/rules.json`

```json
{
  "_description": "Static reminders to include in the recovery section after each compaction. Project-specific. Add or remove entries to match your project's conventions. Keep brief — total recovery section is capped at ~500 tokens (~2000 chars).",
  "reminders": [
    "Verify the file content before claiming an edit is done",
    "Run tests before declaring task complete",
    "Re-read CLAUDE.md if you're unsure of project conventions"
  ]
}
```

---

## Section 3: Validation harness source

The harness is a single bash script that runs each hook against test cases under `validation/test-cases/<hook-name>/`. It substitutes placeholders in `input.json`, pipes JSON to the hook via stdin, captures exit code + stdout + stderr + duration, and asserts against fields in `expected.json`.

**Dependencies:** bash, `jq`, `python3`, `grep`. The harness is intentionally generic — it has no dependencies on the rest of the repo and can be used to validate any Claude Code hook.

#### `validation/harness.sh` (307 lines)

```bash
#!/usr/bin/env bash
# Validation harness for Claude Code hooks.
#
# Usage: ./harness.sh <hook-name>
# Example: ./harness.sh edit-drift-detector
#
# For each test case under test-cases/<hook-name>/:
#   - Optionally runs setup.sh (with TEST_DIR env var set to case directory)
#   - Substitutes placeholders in input.json:
#       {{FIXTURE_PATH}} → absolute path of fixture.txt (if present)
#       {{PROJECT_PATH}} → absolute path of project/ directory (if present)
#       {{TEST_DIR}}     → absolute path of the test case directory
#   - Pipes the resulting JSON to the hook's hook.py via stdin
#   - Captures exit code, stdout, stderr, duration
#   - Compares against expected.json fields:
#       expected_exit_code (required)
#       expected_stderr_contains[] (optional)
#       expected_stdout_contains[] (optional)
#
# Writes per-run results to results/<hook-name>-<timestamp>.json.

set -o pipefail

HOOK_NAME="${1:-edit-drift-detector}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_PATH="$REPO_DIR/hooks/$HOOK_NAME/hook.py"
TEST_DIR_BASE="$SCRIPT_DIR/test-cases/$HOOK_NAME"
RESULTS_DIR="$SCRIPT_DIR/results"

if [ ! -f "$HOOK_PATH" ]; then
  echo "Hook not found: $HOOK_PATH" >&2
  exit 1
fi
if [ ! -d "$TEST_DIR_BASE" ]; then
  echo "Test cases not found: $TEST_DIR_BASE" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required but not installed" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
RESULTS_FILE="$RESULTS_DIR/$HOOK_NAME-$TIMESTAMP.json"

PASS=0
FAIL=0
FALSE_POSITIVE=0
FALSE_NEGATIVE=0
TOTAL_DURATION_MS=0

RESULTS_TMP="$(mktemp)"
echo "[]" > "$RESULTS_TMP"

echo "Validation: $HOOK_NAME"
echo "Hook: $HOOK_PATH"
echo "Tests: $TEST_DIR_BASE"
echo "----------------------------------------"

for case_dir in "$TEST_DIR_BASE"/*/; do
  [ -d "$case_dir" ] || continue
  case_dir="${case_dir%/}"
  case_name="$(basename "$case_dir")"
  input_template="$case_dir/input.json"
  expected="$case_dir/expected.json"

  if [ ! -f "$input_template" ] || [ ! -f "$expected" ]; then
    echo "SKIP $case_name (missing input.json or expected.json)"
    continue
  fi

  # Optional setup script: runs before the hook with TEST_DIR exported
  if [ -x "$case_dir/setup.sh" ]; then
    TEST_DIR="$case_dir" bash "$case_dir/setup.sh" >/dev/null 2>&1 || true
  fi

  # Build input by substituting placeholders
  input_json="$(cat "$input_template")"
  if [ -f "$case_dir/fixture.txt" ]; then
    fixture_path="$case_dir/fixture.txt"
    input_json="${input_json//\{\{FIXTURE_PATH\}\}/$fixture_path}"
  fi
  if [ -d "$case_dir/project" ]; then
    project_path="$case_dir/project"
    input_json="${input_json//\{\{PROJECT_PATH\}\}/$project_path}"
  fi
  input_json="${input_json//\{\{TEST_DIR\}\}/$case_dir}"

  expected_exit="$(jq -r '.expected_exit_code' "$expected")"
  description="$(jq -r '.description' "$expected")"
  category="$(jq -r '.category' "$expected")"

  # Build env var prefix from optional .env field in expected.json.
  # Env values support same placeholders as input.json.
  env_args=()
  while IFS= read -r kv; do
    [ -z "$kv" ] && continue
    kv="${kv//\{\{TEST_DIR\}\}/$case_dir}"
    if [ -f "$case_dir/fixture.txt" ]; then
      kv="${kv//\{\{FIXTURE_PATH\}\}/$case_dir/fixture.txt}"
    fi
    if [ -d "$case_dir/project" ]; then
      kv="${kv//\{\{PROJECT_PATH\}\}/$case_dir/project}"
    fi
    env_args+=("$kv")
  done < <(jq -r '.env // {} | to_entries[]? | "\(.key)=\(.value)"' "$expected" 2>/dev/null)

  # Run hook, capture stdout + stderr separately, with duration
  stdout_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  set +e
  if [ ${#env_args[@]} -gt 0 ]; then
    echo "$input_json" | env "${env_args[@]}" python3 "$HOOK_PATH" >"$stdout_tmp" 2>"$stderr_tmp"
  else
    echo "$input_json" | python3 "$HOOK_PATH" >"$stdout_tmp" 2>"$stderr_tmp"
  fi
  actual_exit=$?
  set -e
  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  duration=$((end_ms - start_ms))
  TOTAL_DURATION_MS=$((TOTAL_DURATION_MS + duration))

  actual_stdout="$(cat "$stdout_tmp")"
  actual_stderr="$(cat "$stderr_tmp")"
  rm -f "$stdout_tmp" "$stderr_tmp"

  # Optional cleanup script
  if [ -x "$case_dir/cleanup.sh" ]; then
    TEST_DIR="$case_dir" bash "$case_dir/cleanup.sh" >/dev/null 2>&1 || true
  fi

  # Determine pass/fail
  passed=true
  failure_reasons=()

  if [ "$actual_exit" != "$expected_exit" ]; then
    passed=false
    failure_reasons+=("exit code: expected $expected_exit, got $actual_exit")
    if [ "$expected_exit" = "0" ] && [ "$actual_exit" = "2" ]; then
      FALSE_POSITIVE=$((FALSE_POSITIVE + 1))
    elif [ "$expected_exit" = "2" ] && [ "$actual_exit" = "0" ]; then
      FALSE_NEGATIVE=$((FALSE_NEGATIVE + 1))
    fi
  fi

  # Verify expected_stderr_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if ! echo "$actual_stderr" | grep -q -- "$pattern"; then
      passed=false
      failure_reasons+=("stderr missing pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stderr_contains[]?' "$expected")

  # Verify expected_stdout_contains
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if ! echo "$actual_stdout" | grep -q -- "$pattern"; then
      passed=false
      failure_reasons+=("stdout missing pattern: '$pattern'")
    fi
  done < <(jq -r '.expected_stdout_contains[]?' "$expected")

  # Verify expected_file_contains (if specified)
  # Format: { "path": "...", "patterns": ["pattern1", "pattern2"] }
  # Path supports the same placeholders as input.json substitution.
  expected_file_path="$(jq -r '.expected_file_contains.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$expected_file_path" ]; then
    expected_file_path="${expected_file_path//\{\{TEST_DIR\}\}/$case_dir}"
    if [ -f "$case_dir/fixture.txt" ]; then
      expected_file_path="${expected_file_path//\{\{FIXTURE_PATH\}\}/$case_dir/fixture.txt}"
    fi
    if [ -d "$case_dir/project" ]; then
      expected_file_path="${expected_file_path//\{\{PROJECT_PATH\}\}/$case_dir/project}"
    fi
    if [ ! -f "$expected_file_path" ]; then
      passed=false
      failure_reasons+=("expected_file_contains: file not found at $expected_file_path")
    else
      file_content="$(cat "$expected_file_path")"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if ! echo "$file_content" | grep -q -- "$pattern"; then
          passed=false
          failure_reasons+=("file '$expected_file_path' missing pattern: '$pattern'")
        fi
      done < <(jq -r '.expected_file_contains.patterns[]?' "$expected")
    fi
  fi

  # Verify expected_file_not_contains (if specified)
  not_file_path="$(jq -r '.expected_file_not_contains.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$not_file_path" ]; then
    not_file_path="${not_file_path//\{\{TEST_DIR\}\}/$case_dir}"
    if [ -f "$case_dir/fixture.txt" ]; then
      not_file_path="${not_file_path//\{\{FIXTURE_PATH\}\}/$case_dir/fixture.txt}"
    fi
    if [ -d "$case_dir/project" ]; then
      not_file_path="${not_file_path//\{\{PROJECT_PATH\}\}/$case_dir/project}"
    fi
    if [ -f "$not_file_path" ]; then
      file_content="$(cat "$not_file_path")"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if echo "$file_content" | grep -q -- "$pattern"; then
          passed=false
          failure_reasons+=("file '$not_file_path' should NOT contain pattern: '$pattern'")
        fi
      done < <(jq -r '.expected_file_not_contains.patterns[]?' "$expected")
    fi
    # If file doesn't exist, "not contains" is trivially satisfied.
  fi

  # Verify expected_file_pattern_count (if specified)
  # Format: { "path": "...", "pattern": "...", "count": N }
  count_file_path="$(jq -r '.expected_file_pattern_count.path // empty' "$expected" 2>/dev/null)"
  if [ -n "$count_file_path" ]; then
    count_file_path="${count_file_path//\{\{TEST_DIR\}\}/$case_dir}"
    count_pattern="$(jq -r '.expected_file_pattern_count.pattern' "$expected")"
    expected_count="$(jq -r '.expected_file_pattern_count.count' "$expected")"
    if [ -f "$count_file_path" ]; then
      actual_count="$(grep -c -- "$count_pattern" "$count_file_path" || echo 0)"
      if [ "$actual_count" != "$expected_count" ]; then
        passed=false
        failure_reasons+=("file '$count_file_path' has $actual_count occurrences of '$count_pattern', expected $expected_count")
      fi
    else
      passed=false
      failure_reasons+=("expected_file_pattern_count: file not found at $count_file_path")
    fi
  fi

  if $passed; then
    PASS=$((PASS + 1))
    printf "PASS  %-30s (%dms) %s\n" "$case_name" "$duration" "$description"
  else
    FAIL=$((FAIL + 1))
    printf "FAIL  %-30s (%dms) %s\n" "$case_name" "$duration" "$description"
    for r in "${failure_reasons[@]}"; do
      printf "       Reason: %s\n" "$r"
    done
    if [ -n "$actual_stderr" ]; then
      printf "       Actual stderr (first 200 chars):\n"
      echo "$actual_stderr" | head -c 200 | sed 's/^/         /'
      echo
    fi
    if [ -n "$actual_stdout" ]; then
      printf "       Actual stdout (first 200 chars):\n"
      echo "$actual_stdout" | head -c 200 | sed 's/^/         /'
      echo
    fi
  fi

  pass_bool=$([ "$passed" = "true" ] && echo "true" || echo "false")
  if [ ${#failure_reasons[@]} -eq 0 ]; then
    reasons_json="[]"
  else
    reasons_json=$(printf '%s\n' "${failure_reasons[@]}" | jq -R . | jq -s .)
  fi
  new_entry=$(jq -n \
    --arg name "$case_name" \
    --arg desc "$description" \
    --arg cat "$category" \
    --argjson exp_exit "$expected_exit" \
    --argjson act_exit "$actual_exit" \
    --argjson duration "$duration" \
    --arg stdout "$actual_stdout" \
    --arg stderr "$actual_stderr" \
    --argjson passed "$pass_bool" \
    --argjson reasons "$reasons_json" \
    '{name: $name, description: $desc, category: $cat, expected_exit: $exp_exit, actual_exit: $act_exit, duration_ms: $duration, stdout: $stdout, stderr: $stderr, passed: $passed, failure_reasons: $reasons}')
  jq --argjson e "$new_entry" '. + [$e]' "$RESULTS_TMP" > "${RESULTS_TMP}.new" && mv "${RESULTS_TMP}.new" "$RESULTS_TMP"
done

TOTAL=$((PASS + FAIL))
echo "----------------------------------------"
echo "Total: $TOTAL  Passed: $PASS  Failed: $FAIL"
echo "False positives (blocked when should pass): $FALSE_POSITIVE"
echo "False negatives (allowed when should block): $FALSE_NEGATIVE"
if [ "$TOTAL" -gt 0 ]; then
  AVG_DURATION=$((TOTAL_DURATION_MS / TOTAL))
  echo "Avg duration: ${AVG_DURATION}ms  Total: ${TOTAL_DURATION_MS}ms"
fi

results_array=$(cat "$RESULTS_TMP")
jq -n \
  --arg hook "$HOOK_NAME" \
  --arg ts "$TIMESTAMP" \
  --argjson pass "$PASS" \
  --argjson fail "$FAIL" \
  --argjson total "$TOTAL" \
  --argjson fp "$FALSE_POSITIVE" \
  --argjson fn "$FALSE_NEGATIVE" \
  --argjson total_dur "$TOTAL_DURATION_MS" \
  --argjson results "$results_array" \
  '{hook: $hook, timestamp: $ts, summary: {pass: $pass, fail: $fail, total: $total, false_positive: $fp, false_negative: $fn, total_duration_ms: $total_dur}, results: $results}' \
  > "$RESULTS_FILE"

rm -f "$RESULTS_TMP"
echo
echo "Results: $RESULTS_FILE"

exit "$FAIL"
```

---

## Section 4: Validation results

Full output of `make test` from this audit run (2026-05-08):

```
=== edit-drift-detector ===
Validation: edit-drift-detector
Hook: /Users/shadi/code/claude-meta-skills/hooks/edit-drift-detector/hook.py
Tests: /Users/shadi/code/claude-meta-skills/validation/test-cases/edit-drift-detector
----------------------------------------
PASS  01-complete-mismatch           (144ms) old_string totally unrelated to file content (hits no_close_match path)
PASS  02-recall-drift                (75ms)  old_string close to actual but with wrong word (cost vs price); fuzzy match should surface real content
PASS  03-stale-content               (78ms)  old_string matches what file used to contain (v1) but not current state (v2/v3)
PASS  04-whitespace-mismatch         (77ms)  old_string has 4-space indent where file has tab indent (real whitespace drift, not trailing-whitespace-only)
PASS  05-partial-line                (76ms)  old_string is a one-line version of a two-line definition (cuts mid-expression in a way the file structure doesn't have)
PASS  06-exact-match                 (74ms)  old_string is an exact substring of file content
PASS  07-multi-line-exact            (73ms)  old_string spans 3 lines, all matching exactly
PASS  08-whitespace-normalized       (75ms)  fixture has trailing spaces in line 1; old_string doesn't. After trailing-whitespace normalization, content matches. Design decision: pass.
PASS  09-single-line                 (76ms)  old_string is a single line matching exactly (degenerate single-line case)
PASS  10-large-file                  (75ms)  old_string matches in middle of 1500-line file (performance test; should complete in well under 500ms)
PASS  11-binary-file                 (76ms)  Binary file (PNG header bytes); hook reads with errors='replace', no match, must not crash; blocking is fine since the text old_string genuinely isn't in the binary
----------------------------------------
Total: 11  Passed: 11  Failed: 0
False positives (blocked when should pass): 0
False negatives (allowed when should block): 0
Avg duration: 81ms  Total: 899ms

=== construction-gate ===
PASS  01-node-modules                (70ms)  Write to node_modules path → blocked
PASS  02-env-file                    (73ms)  Write to .env.production → blocked
PASS  03-git-internals               (83ms)  Write deep into .git/ internals → blocked; confirms regex matches anywhere in path
PASS  04-normal-path                 (74ms)  Normal write to src/app.py → allowed
PASS  05-tmp-scratch                 (74ms)  Write to /tmp scratch file → allowed
PASS  06-filename-contains-protected-string (70ms)  Filename contains 'node_modules' substring but NOT as a directory path; pattern 'node_modules/' should NOT match (boundary test)
PASS  07-invalid-regex               (88ms)  rules.json contains an invalid regex; hook skips it gracefully and still enforces the valid 'node_modules/' pattern. Doesn't crash on bad regex.
----------------------------------------
Total: 7  Passed: 7  Failed: 0
False positives (blocked when should pass): 0
False negatives (allowed when should block): 0
Avg duration: 76ms  Total: 532ms

=== silent-file-verifier ===
PASS  01-missing-file                (90ms)  Write reported success but file doesn't exist on disk (ghost-file problem)
PASS  02-zero-bytes-with-content     (75ms)  Write reported success but file is 0 bytes despite non-empty content provided
PASS  03-write-with-content          (75ms)  Write succeeded; file exists with non-empty content; hook silently allows
PASS  04-edit-existing               (68ms)  Edit succeeded; file exists; hook silently allows (no size check on Edit)
PASS  05-empty-write-empty-content   (74ms)  Write of intentionally empty content; resulting 0-byte file is correct (no warning)
PASS  06-path-with-spaces            (86ms)  Path containing spaces; hook should handle correctly (no warning, file exists)
PASS  07-multiedit-missing           (94ms)  MultiEdit reported success but file doesn't exist; hook must warn (matcher coverage extended to MultiEdit/NotebookEdit beyond Write/Edit)
----------------------------------------
Total: 7  Passed: 7  Failed: 0
False positives (blocked when should pass): 0
False negatives (allowed when should block): 0
Avg duration: 80ms  Total: 562ms

=== completion-verifier ===
PASS  01-node-failing                (441ms) Node project with failing test command (npm test exits non-zero)
PASS  02-python-failing              (178ms) Python project with failing unittest (assertion fails)
PASS  03-build-failure               (107ms) Makefile-based project with simulated build failure (make test exits non-zero)
PASS  04-node-passing                (236ms) Node project with passing tests (npm test exits 0); hook allows stop silently
PASS  05-python-passing              (159ms) Python project with passing unittest tests; hook allows stop silently
PASS  06-no-project                  (81ms)  Empty project dir with no recognizable config files; hook should pass through
PASS  07-stop-hook-active            (86ms)  stop_hook_active=true must exit immediately to prevent infinite loop (issues #3573, #10205)
PASS  08-timeout                     (2098ms) Long-running test (sleep 5) with COMPLETION_VERIFIER_TIMEOUT_SECS=2 must produce timeout warning, not block
PASS  09-transcript-with-writes      (103ms) Transcript shows Edit tool_use; failing tests; hook should run tests and block
PASS  10-transcript-without-writes   (153ms) Critical: transcript shows only Read/Bash/Glob (no writes); tests would FAIL if run, but hook must skip them (exploration session) and exit silently
PASS  11-malformed-transcript        (128ms) Malformed transcript (no valid JSON lines); hook must fall back to running tests (per spec, accept FP risk when transcript unreadable)
PASS  12-cargo-not-installed         (87ms)  Cargo project but cargo not installed in PATH; hook should emit command-not-found warning and allow stop (FileNotFoundError handler)
----------------------------------------
Total: 12  Passed: 12  Failed: 0
False positives (blocked when should pass): 0
False negatives (allowed when should block): 0
Avg duration: 321ms  Total: 3857ms

=== context-recovery ===
PASS  01-git-repo-with-claude-md     (157ms) Git repo with CLAUDE.md; recovery section gets git state appended; original content preserved
PASS  02-non-git-directory           (93ms)  Non-git directory; recovery section has reminders + timestamp but no git fields
PASS  03-no-claude-md                (95ms)  No CLAUDE.md exists; hook creates one with recovery section
PASS  04-idempotent-replace          (93ms)  Idempotent replace: existing recovery section replaced, not duplicated. Original content preserved.
PASS  05-content-updates             (168ms) Content updates between runs: new recovery section reflects current git state, replacing stale data
PASS  06-read-only-claude-md         (93ms)  Read-only CLAUDE.md; hook exits 0 silently without crashing; original file unchanged
PASS  07-token-budget                (208ms) 200 modified files exceeds token budget; recovery section truncates modified-files list with [truncated] marker
PASS  08-claude-project-dir-env      (102ms) CLAUDE_PROJECT_DIR env var override: hook writes to env path, not cwd
----------------------------------------
Total: 8  Passed: 8  Failed: 0
False positives (blocked when should pass): 0
False negatives (allowed when should block): 0
Avg duration: 126ms  Total: 1009ms
```

### Aggregate summary

| Hook | Tests | Pass | FP | FN | Avg duration | Total |
|---|---|---|---|---|---|---|
| edit-drift-detector | 11 | 11 | 0 | 0 | 81 ms | 899 ms |
| construction-gate | 7 | 7 | 0 | 0 | 76 ms | 532 ms |
| silent-file-verifier | 7 | 7 | 0 | 0 | 80 ms | 562 ms |
| completion-verifier | 12 | 12 | 0 | 0 | 321 ms | 3857 ms |
| context-recovery | 8 | 8 | 0 | 0 | 126 ms | 1009 ms |
| **Total** | **45** | **45** | **0** | **0** | — | **6859 ms** |

**Timing caveat:** Durations include ~30–40 ms of Python startup overhead from the harness measurement method (each measurement invokes `python3 -c "import time; print(...)"` to capture timestamps). Real hook execution overhead when installed in Claude Code is approximately 30–45 ms lower than reported values. The 2098 ms in `completion-verifier` test 08 is dominated by the 2-second timeout the test exercises — that's expected behavior, not overhead.

---

## Section 5: Architecture decisions and rationale

Each major decision: what was decided, what alternatives existed, why this choice.

### Decision 1 — PreCompact + CLAUDE.md modification, not SessionStart:compact

**Decision:** `context-recovery` is a `PreCompact` hook that writes a recovery section into `CLAUDE.md` (auto-reloads after compaction). Idempotent merge via HTML comment delimiters; atomic file write.

**Alternative:** The official Claude Code docs example uses `SessionStart` with `"matcher": "compact"` and writes recovery content to stdout. Several ecosystem implementations (e.g., `Dicklesworthstone/post_compact_reminder`) follow this pattern.

**Why this choice:** That pattern is broken per Claude Code GitHub issue #15174 — the hook fires but its stdout is NOT injected into Claude's context after compaction. Implementations using it ship hooks that fire-but-do-nothing. The verified working path is CLAUDE.md modification, which auto-reloads after compaction. This is the workaround documented on the issue itself. There is no `PostCompact` event (issues #14258, #40492, #32026 are all open feature requests), so `PreCompact` is the only event that fires reliably around compaction.

### Decision 2 — Command-safety hook deliberately not built

**Decision:** No `PreToolUse:Bash` safety hook. Out of scope.

**Alternative:** Build an 8th regex-based command safety hook covering common dangerous patterns (`rm -rf`, `sudo`, etc.).

**Why this choice:** The ecosystem has at least seven existing implementations: `claude-warden` (AST-based bash parsing with `bash-parser`, far more sophisticated than regex), Claude Code Auto Mode (Anthropic's built-in transcript classifier, March 2026), `snagnever/sidecar` (TOML-based block/allow/ask/alter policies), the hookify plugin, yamazaki's `enforce-permissions.sh`, native Claude Code permission deny rules, and `danielmiessler/PAI`. Building an 8th regex-based version would be convergent without adding value and would dilute claude-meta-skills' positioning. We explicitly delegate command safety and call out the alternatives in the README.

### Decision 3 — construction-gate is protected-paths-only (no TODO check)

**Decision:** `construction-gate` does only path-pattern matching against a configurable list. No TODO/placeholder content scanning.

**Alternative:** Add a TODO regex check (e.g., flag `TODO`, `FIXME`, placeholder strings in newly written content).

**Why this choice:** `danielmiessler/PAI` already does a comprehensive TODO regex check. Building a thinner version would be convergent. Our value-add over PAI is the validation suite (45/45 measured) plus the small-file Python implementation; the patterns themselves are well-trodden ground. The `rules.json` design lets users add their own patterns including TODO ones if they want.

### Decision 4 — Inline `log_fire()` duplicated 5x, not a shared library

**Decision:** Each hook contains its own copy of the `log_fire()` function (~17 lines, identical across hooks). No `hooks/_lib/log.py` or similar.

**Alternative:** Extract `log_fire()` to a shared module imported by each hook (`from _lib.log import log_fire`).

**Why this choice:** Sharing a lib would require either (a) a sibling import from each hook's directory, which needs `sys.path` manipulation and is fragile across install layouts, or (b) installing the shared lib into a known location, which complicates `install.sh`. Inlining is a bounded DRY violation: ~17 lines × 5 hooks = 85 duplicated lines, all identical. If we change the schema, we touch 5 files instead of 1 — manageable. The function is wrapped in `try/except: pass` so a logging failure can never crash a hook (this is critical — hooks are on the tool-call path).

### Decision 5 — HTML comment delimiters for the recovery section

**Decision:** `context-recovery` writes between `<!-- post-compact-recovery-start -->` and `<!-- post-compact-recovery-end -->` markers in CLAUDE.md.

**Alternative:** Use a unique heading like `## Auto-recovery (claude-meta-skills)` as the boundary marker.

**Why this choice:** HTML comments are a standard markdown convention for invisible markers. The hook reads/writes raw file content, so the delimiter always works at the file level — that's mechanically what we need. Whether Claude sees the markers in rendered context is uncertain (possibly stripped, possibly visible) but benign either way. A heading would render in Claude's context, adding noise to every recovery cycle. Comments are quieter.

### Decision 6 — Atomic write via `tempfile.mkstemp` + `os.replace`

**Decision:** `context-recovery` writes to a temp file and atomically renames it to CLAUDE.md.

**Alternative:** Direct `open(path, 'w').write(content)`.

**Why this choice:** If the hook is killed mid-write (process termination, signal), a direct write leaves CLAUDE.md half-written or empty. `os.replace` is atomic on POSIX — the file either has the old content or the new content, never partial. The temp file is created in the same directory (so `os.replace` is atomic even across same-filesystem boundaries). We checked: the only case where this fails is the parent directory being read-only, which we explicitly handle with a `skip-error` log and exit 0.

### Decision 7 — Synchronous mode only (no `"async": true`)

**Decision:** All five hooks run synchronously. The `templates/settings.json` does not set `"async": true`.

**Alternative:** Use async mode for hooks that don't block the tool call (e.g., `silent-file-verifier`, `context-recovery`) to avoid adding latency.

**Why this choice:** Claude Code GitHub issue #38162 documents that async hooks on macOS receive empty stdin (the bug is in the IPC layer, not the hook). Since the audit/development environment is macOS and the team builds on macOS, async would silently break stdin parsing. Sync mode adds ~50–80 ms per hook fire — acceptable. We document the bug in known limitations.

### Decision 8 — `.git`-direct-only scope for context-recovery

**Decision:** `context-recovery` only collects git context if `cwd` (or `$CLAUDE_PROJECT_DIR`) directly contains a `.git` entry. No parent-walk to find the repo.

**Alternative:** Use `git rev-parse --show-toplevel` to find the enclosing repo regardless of how deep `cwd` is.

**Why this choice:** During Phase 3 validation, test 02 (non-git directory) initially failed because the test fixture lived inside the claude-meta-skills repo, and `git rev-parse` walked up and surfaced the parent repo's branch/commits. That's the wrong context for the user's actual project. Direct-check prevents picking up unrelated parent-repo state when test fixtures or scratch dirs live inside a larger repo. Real-world impact: Claude Code typically sets `$CLAUDE_PROJECT_DIR` to the project root (which has `.git`), so this check passes in normal use. Subdirectory invocations without `$CLAUDE_PROJECT_DIR` fall through to skip — safe failure mode (no git context surfaced rather than the wrong one).

---

## Section 6: Ecosystem positioning

Honest comparison — what we do vs what adjacent projects do.

### Adjacent projects

- **[obra/superpowers](https://github.com/obra/superpowers)** (~150–176K stars per recent counts) — Methodology framework: TDD, planning, code-review skills. Operates at the agent-workflow level, not the tool-call level. Different scope; complementary. We don't compete.
- **[claude-warden](https://github.com/banyudu/claude-warden)** (~24 stars) — AST-based bash command safety using `bash-parser`. Far more sophisticated than regex blocking; can reason about argument boundaries (`rm -rf` vs `rm -rf "$VAR"` where `$VAR` is empty). We deliberately don't do command safety — claude-warden covers it better.
- **[Claude Code Auto Mode](https://www.anthropic.com/engineering/claude-code-auto-mode)** (Anthropic, shipped March 2026) — Model-level transcript classifier for auto-approving/blocking actions. Probabilistic (transcript-based), our hooks are deterministic (input-based). Complementary: Auto Mode is for when the user wants "trust the model"; hooks are for "always check structurally regardless".
- **[Claude-Mem](https://docs.claude-mem.ai/)** — Persistent cross-session memory with SQLite + vector search. Heavier than our PreCompact + CLAUDE.md recovery; different problem class. We solve "preserve state across one compaction"; Claude-Mem solves "preserve knowledge across all sessions forever".
- **[snagnever/claude-code-sidecar](https://github.com/snagnever/claude-code-sidecar)** — TOML-based command policies with block/allow/ask/alter actions. More configurable than our hooks for command safety. We don't do command safety; sidecar covers that space.
- **[omerkaz/claude-code-ts-quality-hook](https://github.com/omerkaz/claude-code-ts-quality-hook)** — TypeScript-specific quality (tsc, ESLint, Prettier). Language-specific. Our `silent-file-verifier` and `completion-verifier` are language-agnostic structural checks; complementary, not competing.
- **[danielmiessler/Personal_AI_Infrastructure (PAI)](https://github.com/danielmiessler/Personal_AI_Infrastructure)** — Protected paths + TODO regex + security patterns. Our `construction-gate` overlaps on protected paths (Decision 3). Our value-add is the validation suite, not the patterns. PAI's TODO regex is more comprehensive than ours; we delegate.

### Explicit non-goals

- Command safety (`PreToolUse:Bash`)
- Agent workflow methodology (TDD, planning, code review skills)
- Persistent cross-session memory
- Observability dashboards / WebSocket UIs
- Marketplace plugin distribution
- Language-specific code quality (TypeScript-specific lints, Python-specific linters, etc.)

These are explicitly delegated to better-positioned ecosystem projects.

---

## Section 7: Known limitations (complete list)

Compiled from per-hook READMEs and the project README.

### Cross-cutting

- **Cross-platform:** Hooks invoke `python3` directly. On Windows native (no WSL), `python3` may not be in PATH; use `python` or alias accordingly. Tested on macOS Darwin 25 and Linux. Windows native untested.
- **GitHub issue #15174 (`SessionStart:compact` broken):** The matcher fires but stdout is not injected into post-compaction context. Our `context-recovery` uses `PreCompact` + CLAUDE.md modification (verified working path) instead.
- **No `PostCompact` event exists** per Claude Code lifecycle (issues #14258, #40492, #32026 are open feature requests). We rely on CLAUDE.md auto-reload after compaction.
- **GitHub issue #38162 (macOS async stdin bug):** `"async": true` causes empty stdin on macOS. All our hooks default to synchronous mode (the correct choice).
- **Validation harness timing includes ~30–40 ms of Python startup overhead** per measurement. Real hook execution overhead when installed in Claude Code is ~30–45 ms lower than reported values.
- **`construction-gate` is convergent with ecosystem.** Patterns are well-trodden ground. Our value-add is the validation suite, not novel patterns.
- **No CI/CD integration.** The validation harness runs locally; `make test` works in any shell. GitHub Actions wiring is a future enhancement.
- **No marketplace distribution.** Install via `git clone` + `install.sh`. Plugin marketplace listing is a future enhancement.

### `edit-drift-detector`

- **GitHub issue #13744** — PreToolUse exit 2 has been reported as unreliable for blocking Edit in some Claude Code versions. If observed, switch to JSON-based blocking (`{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "..."}}` with exit 0).
- **GitHub issue #15528** — PreToolUse hooks reading the target file can race with Claude Code's own file state ("File has been unexpectedly modified" errors). This hook is read-only on the target file, so it should not trigger this race directly. Worth monitoring.
- **GitHub issue #11807** — PreToolUse hook success can freeze the VS Code extension (terminal Claude Code unaffected). Test on target environment before relying.
- **Multi-line `old_string` with internal blank lines** — `difflib`'s similarity may underestimate match quality. The 0.6 threshold is permissive; tune in Phase 2+ if false negatives surface.
- **Large files (10K+ lines)** — sliding-window comparison is O(file_lines × old_lines × line_chars). For very large files with multi-line `old_string`, latency may exceed the 500 ms target. The 1500-line test (case 10) completes well under target; 10K+ untested.
- **Relative paths untested.** All test fixtures use absolute paths via `{{FIXTURE_PATH}}` substitution. Real Claude Code sometimes provides relative paths; the hook calls `os.path.exists(file_path)` directly which resolves relative to the hook process's cwd, not necessarily Claude's cwd. Behavior on relative paths is uncertain.
- **Line endings (`\r\n` vs `\n`) treated as real content differences.** A file with Windows line endings vs an `old_string` with Unix line endings will not match exactly and will not normalize. Design decision: line endings carry meaning in some codebases.
- **Binary files: blocks rather than skips.** Test 11 confirms the hook reads binary content (with `errors="replace"`) without crashing, but a text `old_string` won't match binary content and the hook will block with a no-close-match message. Correct behavior, but the message could be improved to suggest "use Write to replace".

### `construction-gate`

- **GitHub issue #13744:** PreToolUse exit 2 reliability — same caveat as `edit-drift-detector`.
- **Path matching is regex, not git-aware.** A pattern like `\.git/` blocks all `.git` paths, including in nested git submodules and bare repos. Generally desirable.
- **No allowlist override.** If a user wants to write to a protected path intentionally (e.g., updating a lock file as part of a controlled refactor), they must temporarily disable the hook or modify `rules.json`. No "this one time only" mechanism.
- **Convergent with ecosystem** (PAI, snagnever/sidecar, native Claude Code permission deny rules). Our value-add is the validation suite.

### `silent-file-verifier`

- **PostToolUse can't block.** PostToolUse fires AFTER the tool ran. Even if the hook detects a problem, the operation already completed. The hook provides feedback via `additionalContext` so Claude sees the discrepancy on the next turn and can correct.
- **Race conditions on networked filesystems.** If the file path resolves to a remote mount with high latency, the hook may fire a missing-file warning before the file fully syncs. Window is narrow (hooks are synchronous post-tool) but real.
- **Symlinks.** `os.path.exists` follows symlinks. If Claude wrote through a broken symlink, the hook will flag it (correct behavior).
- **Permissions.** If the file exists but the hook lacks read permission to check size, hook exits 0 silently rather than warning. Intentional — permission errors aren't ghost-file problems.
- **NotebookEdit covered by code path but not by a dedicated test fixture** (NotebookEdit operates on .ipynb files; meaningful test requires a notebook fixture). Code falls back to `notebook_path` if `file_path` missing.
- **No content correctness check.** Hook verifies file exists and (for Write) that size is non-zero when content was non-empty. It does NOT verify that the file content matches what was supposed to be written. Out of scope.
- **File-path-is-actually-a-directory edge case.** If `file_path` points to an existing directory, `os.path.exists` returns True and `os.path.getsize` returns the directory entry size, not file size. Degenerate case; hook would not catch it.

### `completion-verifier`

- **Issues #3573, #10205:** Stop hook infinite loops if `stop_hook_active` not checked. We check first thing; verified in test 07.
- **Issues #15813, #8564, #3019, #3046:** `transcript_path` can be stale, point to wrong file, or be missing. When transcript is unreadable, we default to running tests (false-positive risk).
- **False-positive risk on exploration sessions with unreadable transcript.** If transcript can't be read AND a project has pre-existing test failures unrelated to the current Claude session, this hook will block completion. Mitigation: Claude can note "tests were already failing before this session", which the hook will allow on next stop attempt (`stop_hook_active` will be true).
- **Project type ambiguity.** A repo with both `package.json` and `pyproject.toml` will use npm only. Workaround: Makefile target.
- **Subdirectory project detection: only checks immediate cwd.** If Claude is in `src/` but `package.json` is at the project root, this hook will not detect the project type. npm and cargo themselves walk up parent directories; this hook does not. Workaround: invoke Claude from project root, or define a top-level `Makefile test:` target.
- **Transcript schema drift risk.** `transcript_has_writes` parses the JSONL transcript by looking for `message.content[].type == "tool_use"` with `name in ("Write", "Edit", "MultiEdit", "NotebookEdit")`. If Claude Code changes the transcript format (e.g., to `tool_call` instead of `tool_use`, or wraps blocks differently), the function returns `False` (no writes found) and the hook silently skips test running on real edit sessions. Quiet failure mode.
- **Test command timeout truncates output capture.** When `subprocess.TimeoutExpired` fires, Python's subprocess returns no captured output for the truncated portion. The hook emits a "test timed out" warning but doesn't include the partial test output that ran before timeout.
- **Anti-loop check only catches the documented loop pattern.** `stop_hook_active=true` is the documented signal Claude Code sends when forced-continuation is in progress. If a future Claude Code version changes this signal, the anti-loop protection silently degrades.

### `context-recovery`

- **`$CLAUDE_PROJECT_DIR` not set + cwd is subdirectory:** the hook may write to a CLAUDE.md in the wrong location. Workaround: ensure Claude Code is launched from project root, or rely on `$CLAUDE_PROJECT_DIR` being set (Claude Code typically sets it).
- **Token budget is approximate.** The 2000-char limit is roughly 500 tokens for English text but actual token count depends on tokenizer. Within Boris Cherny's recommended 5000-token CLAUDE.md ceiling regardless.
- **HTML comment delimiter behavior in Claude's context window is unverified.** The hook works correctly at the file level (reads/writes raw text). Whether Claude sees the markers in rendered context is unknown but harmless either way.
- **Race condition window with concurrent CLAUDE.md edits.** If a user edits CLAUDE.md in another editor while the hook fires, atomic-write overwrites their unsaved changes. Window is narrow (hook fires on PreCompact only) but real.
- **`PostCompact` event does not exist.** We rely on CLAUDE.md auto-reload after compaction. If Claude Code changes the post-compaction reload behavior, this hook would silently stop providing context recovery.

---

## Section 8: Test case inventory

All 45 test cases. Category convention: `should-block` (hook should exit 2 / emit decision: block); `should-pass` (hook should exit 0 silently); `should-warn` (hook should exit 0 with additionalContext); `should-write` (context-recovery: hook should write to CLAUDE.md); `should-pass-silently` (context-recovery: hook should exit 0 without writing).

| # | Hook | Case name | Category | Description |
|---|---|---|---|---|
| 1 | edit-drift-detector | 01-complete-mismatch | should-block | old_string totally unrelated to file content (hits no_close_match path) |
| 2 | edit-drift-detector | 02-recall-drift | should-block | old_string close to actual but with wrong word (cost vs price); fuzzy match should surface real content |
| 3 | edit-drift-detector | 03-stale-content | should-block | old_string matches what file used to contain (v1) but not current state (v2/v3) |
| 4 | edit-drift-detector | 04-whitespace-mismatch | should-block | old_string has 4-space indent where file has tab indent (real whitespace drift, not trailing-whitespace-only) |
| 5 | edit-drift-detector | 05-partial-line | should-block | old_string is a one-line version of a two-line definition (cuts mid-expression in a way the file structure doesn't have) |
| 6 | edit-drift-detector | 06-exact-match | should-pass | old_string is an exact substring of file content |
| 7 | edit-drift-detector | 07-multi-line-exact | should-pass | old_string spans 3 lines, all matching exactly |
| 8 | edit-drift-detector | 08-whitespace-normalized | should-pass | fixture has trailing spaces in line 1; old_string doesn't. After trailing-whitespace normalization, content matches. Design decision: pass. |
| 9 | edit-drift-detector | 09-single-line | should-pass | old_string is a single line matching exactly (degenerate single-line case) |
| 10 | edit-drift-detector | 10-large-file | should-pass | old_string matches in middle of 1500-line file (performance test; should complete in well under 500ms) |
| 11 | edit-drift-detector | 11-binary-file | should-block | Binary file (PNG header bytes); hook reads with errors='replace', no match, must not crash; blocking is fine since the text old_string genuinely isn't in the binary |
| 12 | construction-gate | 01-node-modules | should-block | Write to node_modules path → blocked (matches node_modules/ pattern) |
| 13 | construction-gate | 02-env-file | should-block | Write to .env.production → blocked (matches .env pattern) |
| 14 | construction-gate | 03-git-internals | should-block | Write deep into .git/ internals → blocked (matches \.git/ pattern); confirms regex matches anywhere in path |
| 15 | construction-gate | 04-normal-path | should-pass | Normal write to src/app.py → allowed (no protected pattern matches) |
| 16 | construction-gate | 05-tmp-scratch | should-pass | Write to /tmp scratch file → allowed |
| 17 | construction-gate | 06-filename-contains-protected-string | should-pass | Filename contains 'node_modules' substring but NOT as a directory path; pattern 'node_modules/' should NOT match (boundary test) |
| 18 | construction-gate | 07-invalid-regex | should-block | rules.json contains an invalid regex; hook skips it gracefully and still enforces the valid 'node_modules/' pattern. Doesn't crash on bad regex. |
| 19 | silent-file-verifier | 01-missing-file | should-warn | Write reported success but file doesn't exist on disk (ghost-file problem) |
| 20 | silent-file-verifier | 02-zero-bytes-with-content | should-warn | Write reported success but file is 0 bytes despite non-empty content provided |
| 21 | silent-file-verifier | 03-write-with-content | should-pass | Write succeeded; file exists with non-empty content; hook silently allows |
| 22 | silent-file-verifier | 04-edit-existing | should-pass | Edit succeeded; file exists; hook silently allows (no size check on Edit) |
| 23 | silent-file-verifier | 05-empty-write-empty-content | should-pass | Write of intentionally empty content; resulting 0-byte file is correct (no warning) |
| 24 | silent-file-verifier | 06-path-with-spaces | should-pass | Path containing spaces; hook should handle correctly (no warning, file exists) |
| 25 | silent-file-verifier | 07-multiedit-missing | should-warn | MultiEdit reported success but file doesn't exist; hook must warn (matcher coverage extended to MultiEdit/NotebookEdit beyond Write/Edit) |
| 26 | completion-verifier | 01-node-failing | should-block | Node project with failing test command (npm test exits non-zero) |
| 27 | completion-verifier | 02-python-failing | should-block | Python project with failing unittest (assertion fails) |
| 28 | completion-verifier | 03-build-failure | should-block | Makefile-based project with simulated build failure (make test exits non-zero) |
| 29 | completion-verifier | 04-node-passing | should-pass | Node project with passing tests (npm test exits 0); hook allows stop silently |
| 30 | completion-verifier | 05-python-passing | should-pass | Python project with passing unittest tests; hook allows stop silently |
| 31 | completion-verifier | 06-no-project | should-pass | Empty project dir with no recognizable config files; hook should pass through |
| 32 | completion-verifier | 07-stop-hook-active | should-pass | stop_hook_active=true must exit immediately to prevent infinite loop (issues #3573, #10205) |
| 33 | completion-verifier | 08-timeout | should-pass | Long-running test (sleep 5) with COMPLETION_VERIFIER_TIMEOUT_SECS=2 must produce timeout warning, not block |
| 34 | completion-verifier | 09-transcript-with-writes | should-block | Transcript shows Edit tool_use; failing tests; hook should run tests and block |
| 35 | completion-verifier | 10-transcript-without-writes | should-pass | Critical: transcript shows only Read/Bash/Glob (no writes); tests would FAIL if run, but hook must skip them (exploration session) and exit silently |
| 36 | completion-verifier | 11-malformed-transcript | should-block | Malformed transcript (no valid JSON lines); hook must fall back to running tests (per spec, accept FP risk when transcript unreadable) |
| 37 | completion-verifier | 12-cargo-not-installed | should-pass | Cargo project but cargo not installed in PATH; hook should emit command-not-found warning and allow stop (FileNotFoundError handler) |
| 38 | context-recovery | 01-git-repo-with-claude-md | should-write | Git repo with CLAUDE.md; recovery section gets git state appended; original content preserved |
| 39 | context-recovery | 02-non-git-directory | should-write | Non-git directory; recovery section has reminders + timestamp but no git fields |
| 40 | context-recovery | 03-no-claude-md | should-write | No CLAUDE.md exists; hook creates one with recovery section |
| 41 | context-recovery | 04-idempotent-replace | should-write | Idempotent replace: existing recovery section replaced, not duplicated. Original content preserved. |
| 42 | context-recovery | 05-content-updates | should-write | Content updates between runs: new recovery section reflects current git state, replacing stale data |
| 43 | context-recovery | 06-read-only-claude-md | should-pass-silently | Read-only CLAUDE.md; hook exits 0 silently without crashing; original file unchanged |
| 44 | context-recovery | 07-token-budget | should-write | 200 modified files exceeds token budget; recovery section truncates modified-files list with [truncated] marker |
| 45 | context-recovery | 08-claude-project-dir-env | should-write | CLAUDE_PROJECT_DIR env var override: hook writes to env path, not cwd |

---

## Section 9: Key research sources

The decisions above are grounded in primary sources (Claude Code GitHub issues, Anthropic engineering posts, ecosystem repos). Listed roughly by load-bearing weight.

1. **https://github.com/anthropics/claude-code/issues/15174** — `SessionStart:compact` fires but stdout is not injected after compaction. Drove Decision 1 (PreCompact + CLAUDE.md modification path).
2. **https://blakecrosley.com/blog/claude-code-hooks** — Blake Crosley's overview of all 95 known hooks across the ecosystem; introduced the four-layer framework (Prevention / Validation / Quality Gating / Context Injection) we organize the suite around.
3. **https://www.anthropic.com/engineering/claude-code-auto-mode** — Anthropic's engineering post on Auto Mode (March 2026); informed Decision 2 (no command-safety hook, since Auto Mode covers the probabilistic-classification space at the model level).
4. **https://github.com/banyudu/claude-warden** — AST-based command safety with `bash-parser`. Reference implementation we deliberately don't compete with (Decision 2).
5. **https://github.com/snagnever/claude-code-sidecar** — TOML-based block/allow/ask/alter command policies. Adjacent ecosystem project.
6. **https://docs.claude-mem.ai/** — Persistent memory system with SQLite + vector search. Different problem class from our PreCompact recovery.
7. **https://github.com/mvara-ai/precompact-hook** — PreCompact hook that spawns a subagent to summarize state into a recovery brief. Inspiration for our PreCompact-based architecture, though we use CLAUDE.md modification rather than subagent summarization.
8. **https://github.com/Dicklesworthstone/post_compact_reminder** — Implementation of the broken `SessionStart:compact` pattern. Showed us what doesn't work; reinforced Decision 1.
9. **https://yuanchang.org/en/posts/claude-code-auto-memory-and-hooks/** — Yuan Chang's post on the Auto Memory + PreCompact pattern. Influenced our PreCompact + CLAUDE.md design.
10. **https://github.com/anthropics/claude-code/issues/38162** — macOS async stdin bug. Drove Decision 7 (sync mode only).
11. **https://github.com/obra/superpowers** — Methodology framework (~150K+ stars). Reference for what we're NOT doing (Section 6 non-goals).
12. **https://github.com/omerkaz/claude-code-ts-quality-hook** — TypeScript-specific quality hooks. Reference for language-specific scope we delegate to.
13. **https://github.com/danielmiessler/Personal_AI_Infrastructure** — Protected paths + TODO regex. Reference for Decision 3 (we don't reimplement TODO checking).
14. **https://www.dotzlaw.com/insights/claude-hooks/** — Argument that feedback loops are more effective than gates. Influenced our constructive-by-default messaging.
15. **https://code.claude.com/docs/en/hooks-guide** — Official Claude Code hooks documentation. Primary reference for event names, payload schemas, exit-code semantics.

Additional references for specific issues mentioned in known limitations:
- https://github.com/anthropics/claude-code/issues/13744 — PreToolUse exit 2 reliability
- https://github.com/anthropics/claude-code/issues/15528 — File-state race during PreToolUse
- https://github.com/anthropics/claude-code/issues/11807 — VS Code extension freeze on hook success
- https://github.com/anthropics/claude-code/issues/3573 — Stop hook infinite loop
- https://github.com/anthropics/claude-code/issues/10205 — Stop hook infinite loop (related)
- https://github.com/anthropics/claude-code/issues/15813, #8564, #3019, #3046 — Transcript path issues
- https://github.com/anthropics/claude-code/issues/14258, #40492, #32026 — PostCompact event feature requests

---

## Section 10: Open questions / areas of uncertainty

Items where we have a working approach but lack definitive evidence:

1. **HTML comment visibility in Claude's rendered CLAUDE.md context.** File-level preservation confirmed (the hook writes the markers; subsequent reads show them). Whether Claude *sees* them in rendered context (i.e., in the assembled system prompt after CLAUDE.md is auto-loaded) is unverified. Behavior is benign either way (markers are syntactically inert markdown), but we don't know.
2. **Real-world false positive rates.** Synthetic FPR is 0% across 45 cases. We have no production data yet — only the construction of the test cases themselves and the dogfood install on this repo. Phase 5+ self-deployment for one week + auto-logging is intended to surface this; data not yet collected at audit time.
3. **Cross-platform Windows compatibility.** Hooks invoke `python3` directly. On Windows native (no WSL), `python3` may not be in PATH. Untested. Linux + macOS Darwin 25 are the validated platforms.
4. **Subdirectory project detection in `completion-verifier`.** Only checks the immediate cwd for project config files (`package.json`, `Cargo.toml`, etc.). Doesn't walk up parent directories the way `npm` and `cargo` do. Workaround documented; impact on real-world usage unknown until self-deployment data arrives.
5. **Transcript schema drift risk in `completion-verifier`.** `transcript_has_writes` parses for `type == "tool_use"` with specific tool names. If Claude Code changes the transcript format, the function returns `False` and the hook silently skips test running. Quiet failure mode worth periodic spot-checks.
6. **Token budget for CLAUDE.md recovery section.** Capped at 2000 chars / ~500 tokens. Optimal size unknown — could be smaller (less context noise) or larger (more useful state). 500 tokens is a guess from Boris Cherny's CLAUDE.md guidance to stay well under the 5000-token total budget.
7. **Whether constructive feedback messages actually improve Claude's self-correction rate vs punitive messages.** A/B testing infrastructure exists (`messages.json` has both `constructive` and `punitive` variants for each hook, switchable via the `default` field). No data collected yet. Hypothesis (constructive > punitive) is unvalidated.

---

## Section 11: Logging and data collection

### Auto-logging system

Each hook calls an inlined `log_fire()` function (Decision 4) when it fires. Log entries are appended (one JSON object per line) to `~/.claude/meta-skills-log.jsonl`. Hooks that allow silently (exit 0 with no output, no warning) do **not** log — only fires that did something get recorded.

**Schema:**

```json
{
  "timestamp": "2026-05-08T22:30:42Z",
  "hook": "edit-drift-detector",
  "action": "block-fuzzy",
  "project": "/Users/shadi/code/flashquest",
  "detail": "file=src/auth.py lines=42-45 similarity=0.91",
  "session_id": "abc123"
}
```

**Action enum:**

| Hook | Actions |
|---|---|
| `edit-drift-detector` | `block-fuzzy` (close match found, suggested correction), `block-no-match` (no similar content found) |
| `construction-gate` | `block` (matched a protected-path pattern) |
| `silent-file-verifier` | `warn-missing` (file not on disk after Write/Edit), `warn-empty` (Write of non-empty content produced 0-byte file) |
| `completion-verifier` | `block` (tests failed), `warn-timeout` (test command timed out), `warn-cmd-missing` (test runner not in PATH), `warn-cwd-missing` (cwd doesn't exist) |
| `context-recovery` | `modify` (replaced existing recovery section), `create` (no CLAUDE.md existed), `skip-readonly` (couldn't read existing CLAUDE.md), `skip-error` (atomic write failed) |

### Privacy boundary

The `detail` field is **metadata only** — enforced by inspection of each hook's source. It contains:

- File paths and pattern names (paths identify but aren't secret)
- Line ranges, similarity ratios, exit codes, byte counts, project type names
- Tool names (Write, Edit, MultiEdit, etc.)

The `detail` field never contains:

- File content, even snippets
- Diff fragments or `old_string`/`new_string` values
- Test output (stdout/stderr from the test command)
- Environment variable values, command arguments beyond the runner name
- User prompts or assistant responses

`detail` is also truncated to 200 characters defensively, in case a future change to detail-string construction inadvertently captures something larger.

### Atomicity and failure modes

The log writer:
- Opens the log file with `os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644`.
- Writes the entire entry in a single `os.write()` call. POSIX guarantees this is atomic for writes < `PIPE_BUF` (4096 bytes); our entries are < 200 bytes, so safe even with concurrent hook fires.
- Wraps everything in a bare `try/except: pass`. A failure to log (disk full, permissions, missing directory we couldn't create) **must never** crash a hook, since hooks are on the tool-call critical path.

### Analyzer

`testing/analyze-log.py` summarizes the log:

```
./testing/analyze-log.py             # last 7 days
./testing/analyze-log.py --days 30   # longer window
./testing/analyze-log.py --redact    # rewrite home prefix to ~ for safer sharing
```

### Current log state at audit time

Output of `./testing/analyze-log.py --redact`:

```
Hook fire summary (last 7 days):

  completion-verifier: 21 fires (15 block, 3 warn-timeout, 3 warn-cmd-missing)
  construction-gate: 12 fires (12 block)
  context-recovery: 24 fires (15 modify, 6 create, 3 skip-error)
  edit-drift-detector: 18 fires (9 block-no-match, 9 block-fuzzy)
  silent-file-verifier: 9 fires (6 warn-missing, 3 warn-empty)

Total: 84 fires across 5 hooks

Top triggered files:
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/01-complete-mismatch/fixture.txt — 3 fires (edit-drift-detector)
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/02-recall-drift/fixture.txt — 3 fires (edit-drift-detector)
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/03-stale-content/fixture.txt — 3 fires (edit-drift-detector)
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/04-whitespace-mismatch/fixture.txt — 3 fires (edit-drift-detector)
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/05-partial-line/fixture.txt — 3 fires (edit-drift-detector)
  ~/code/claude-meta-skills/validation/test-cases/edit-drift-detector/11-binary-file/fixture.txt — 3 fires (edit-drift-detector)
  /Users/test/project/node_modules/package/index.js — 3 fires (construction-gate)
  /Users/test/project/.env.production — 3 fires (construction-gate)
  /Users/test/project/.git/objects/pack/pack-abc123.idx — 3 fires (construction-gate)
  /Users/test/project/node_modules/x/y.js — 3 fires (construction-gate)

Projects:
  /tmp — 30 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/01-node-failing/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/02-python-failing/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/03-build-failure/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/08-timeout/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/09-transcript-with-writes/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/11-malformed-transcript/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/completion-verifier/12-cargo-not-installed/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/context-recovery/01-git-repo-with-claude-md/project — 3 fires
  ~/code/claude-meta-skills/validation/test-cases/context-recovery/02-non-git-directory/project — 3 fires
```

**All 84 fires at audit time are from synthetic validation runs (the `make test` command was run multiple times during build and verification).** The repo has been dogfood-installed on itself but no real-world Claude Code session has yet exercised the hooks against actual project work — this happens in Phase 5+ self-deployment, post-audit.

---

**End of external review package.**

> **Reviewer notes:** the audit is intended to find problems. Suggested focus areas: (a) logic bugs in any of the 5 hook.py files; (b) gaps between Section 5 architecture decisions and what the code actually does; (c) contradictions between per-hook README claims and Section 7 known limitations; (d) ecosystem-positioning claims in Section 6 that overstate or understate what the project actually does; (e) test coverage gaps where Section 8 lists a category but no case actually exercises the failure mode; (f) privacy boundary violations where the `detail` field as constructed in code could leak content despite Section 11 claims it doesn't.
