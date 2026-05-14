#!/usr/bin/env python3
"""
context-recovery hook for Claude Code.

PreCompact hook. Captures session context (git state + static reminders)
and writes a recovery section to CLAUDE.md before compaction. After
compaction, CLAUDE.md auto-reloads with the recovery context preserved.

Architecture: PreCompact + CLAUDE.md modification. Chosen because
SessionStart:compact stdout context injection has had documented failures
(issue #15174), while CLAUDE.md modification is the verified working path
for post-compaction context preservation in this repo. Current Claude Code
docs list PostCompact, but this hook intentionally writes before compaction
via the dogfooded PreCompact path.

Exit 0 always. Claude Code supports PreCompact decision control, but this
hook does not try to block compaction; it fails open.

macOS stdin bug (#38162) only affects async hooks. This hook must be
invoked synchronously (no "async": true in settings.json).
"""
import json
import sys
import os
import re
import subprocess
import tempfile
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

# Delimiters: HTML comments. Standard markdown convention for invisible
# markers. The hook reads/writes raw file content, so the delimiter
# always works at the file level. Whether Claude sees them in rendered
# context is benign either way.
DELIMITER_START = "<!-- post-compact-recovery-start -->"
DELIMITER_END = "<!-- post-compact-recovery-end -->"


def env_int(name, default):
    """Read a positive integer env var, falling back on invalid values."""
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return value if value > 0 else default


GIT_TIMEOUT_SECS = 5
# ~500 tokens; per Boris Cherny CLAUDE.md guidance to stay well under
# the 5000-token total budget.
RECOVERY_SECTION_MAX_CHARS = env_int("CONTEXT_RECOVERY_SECTION_MAX_CHARS", 2000)
CUSTOM_INSTRUCTIONS_MAX_CHARS = env_int("CONTEXT_RECOVERY_CUSTOM_MAX_CHARS", 300)
IN_PROGRESS_EXCLUDED_PREFIXES = (".claude/hooks/meta-skills/",)

CUSTOM_INSTRUCTION_REDACTIONS = [
    re.compile(
        r"(?i)\b([A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|passwd|credential)[A-Za-z0-9_-]*)\s*[:=]\s*[^,\s;]+"
    ),
    re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{12,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}\b"),
]


def resolve_claude_md_path(cwd):
    """
    Return the path where CLAUDE.md should be (whether or not it exists).
    Priority: $CLAUDE_PROJECT_DIR/CLAUDE.md > nearest project marker
    (CLAUDE.md or .git) > cwd/CLAUDE.md.
    """
    return resolve_project_root(cwd) / "CLAUDE.md"


def resolve_project_root(cwd):
    """
    Return the best project root for recovery writes and git context.

    Claude Code normally sets $CLAUDE_PROJECT_DIR, which remains the
    authoritative root. If it is absent, handle subdirectory sessions by
    walking upward to the nearest project marker: an existing CLAUDE.md or
    a .git entry. Falling back to cwd preserves non-git scratch-directory
    behavior.
    """
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir and os.path.isdir(project_dir):
        try:
            return Path(project_dir).expanduser().resolve(strict=False)
        except OSError:
            return Path(project_dir).expanduser()

    if cwd:
        root = Path(cwd)
    else:
        root = Path.cwd()

    try:
        root = root.expanduser().resolve(strict=False)
    except OSError:
        root = root.expanduser()

    if root.exists() and not root.is_dir():
        root = root.parent

    candidates = [root] + list(root.parents)
    for candidate in candidates:
        if (candidate / "CLAUDE.md").is_file() or is_git_root(candidate):
            return candidate

    return root


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


def combine_file_lists(*outputs):
    """Merge newline-delimited git path lists, preserving first-seen order."""
    seen = set()
    files = []
    for output in outputs:
        if not output:
            continue
        for line in output.splitlines():
            path = line.strip()
            if path and include_in_progress_path(path) and path not in seen:
                seen.add(path)
                files.append(path)
    return "\n".join(files) if files else None


def include_in_progress_path(path):
    """True when a git path should appear in the recovery file list."""
    normalized = path.replace("\\", "/")
    return not any(
        normalized.startswith(prefix) for prefix in IN_PROGRESS_EXCLUDED_PREFIXES
    )


def is_git_root(path):
    """True if path contains a .git directory or file (worktree)."""
    if not path:
        return False
    return (Path(path) / ".git").exists()


def gather_git_context(project_root):
    """
    Return dict with branch, commits, and in-progress file paths.

    The internal ``modified_files`` key is kept for compatibility with the
    renderer, but its value includes tracked changes and untracked non-ignored
    files.

    Only collects git context if the resolved project root contains a
    .git directly. Root discovery already chooses either $CLAUDE_PROJECT_DIR,
    an existing CLAUDE.md parent, a nearest .git parent, or cwd; this direct
    check keeps git commands scoped to that chosen root.

    Real-world: Claude Code typically sets $CLAUDE_PROJECT_DIR to project
    root, which has .git, so this check passes. Subdirectory invocations
    without $CLAUDE_PROJECT_DIR now also recover git context when root
    discovery finds a parent git root.
    """
    git_cwd = None
    if project_root and is_git_root(project_root):
        git_cwd = str(project_root)

    if git_cwd is None:
        return {"branch": None, "commits": None, "modified_files": None}

    tracked_files = run_git_command(["diff", "--name-only", "HEAD"], git_cwd)
    untracked_files = run_git_command(
        ["ls-files", "--others", "--exclude-standard"],
        git_cwd,
    )

    return {
        "branch": run_git_command(["branch", "--show-current"], git_cwd),
        "commits": run_git_command(["log", "--oneline", "-5"], git_cwd),
        "modified_files": combine_file_lists(tracked_files, untracked_files),
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


def truncate_with_marker(text, max_chars, marker):
    """Truncate text to max_chars while preserving an explicit marker."""
    if len(text) <= max_chars:
        return text
    if max_chars <= len(marker):
        return marker[:max_chars]
    return text[: max_chars - len(marker)].rstrip() + marker


def redact_secret_match(match):
    """Preserve the secret label where possible, but drop the value."""
    if match.groups():
        return f"{match.group(1).strip()}=[REDACTED]"
    return "[REDACTED]"


def sanitize_custom_instructions(custom_instructions):
    """Return a bounded, secret-redacted custom instruction excerpt."""
    if not custom_instructions:
        return ""

    sanitized = " ".join(str(custom_instructions).split())
    for pattern in CUSTOM_INSTRUCTION_REDACTIONS:
        sanitized = pattern.sub(redact_secret_match, sanitized)

    return truncate_with_marker(
        sanitized,
        CUSTOM_INSTRUCTIONS_MAX_CHARS,
        " [truncated custom instructions]",
    )


def render_section(git_context, reminders, custom_instructions, timestamp,
                   modified_files_limit=None):
    """
    Build the recovery section. If modified_files_limit is set, truncate
    the in-progress file list to that many entries with a [truncated] marker.
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
        lines.append(f"**In-progress files ({len(files)}):**")
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
    """Build recovery section, truncating in-progress files if over budget."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    full = render_section(git_context, reminders, custom_instructions, timestamp)
    if len(full) <= RECOVERY_SECTION_MAX_CHARS:
        return full

    # Over budget. Reduce in-progress file list progressively.
    modified_files = git_context.get("modified_files")
    if not modified_files:
        # No in-progress file list to truncate; enforce the hard section budget.
        return enforce_recovery_section_budget(full)

    file_count = len([f for f in modified_files.split("\n") if f.strip()])
    # Binary-search-ish: try decreasing limits until under budget
    for limit in range(file_count - 1, -1, -1):
        truncated = render_section(
            git_context, reminders, custom_instructions, timestamp,
            modified_files_limit=limit,
        )
        if len(truncated) <= RECOVERY_SECTION_MAX_CHARS:
            return truncated
    # Even with 0 files shown, still over budget. Enforce the hard cap.
    return enforce_recovery_section_budget(render_section(
        git_context, reminders, custom_instructions, timestamp,
        modified_files_limit=0,
    ))


def enforce_recovery_section_budget(section):
    """Hard-cap the recovery block while preserving replacement delimiters."""
    if len(section) <= RECOVERY_SECTION_MAX_CHARS:
        return section
    full_marker = "\n\n[truncated to fit recovery section budget]\n" + DELIMITER_END
    compact_marker = "\n" + DELIMITER_END
    min_delimited_budget = len(DELIMITER_START) + len(compact_marker)
    budget = max(RECOVERY_SECTION_MAX_CHARS, min_delimited_budget)
    available_after_start = budget - len(DELIMITER_START)
    marker = full_marker if len(full_marker) <= available_after_start else compact_marker
    body = section
    if body.endswith(DELIMITER_END):
        body = body[: -len(DELIMITER_END)].rstrip()
    if body.startswith(DELIMITER_START):
        body = body[len(DELIMITER_START):].lstrip()
    keep = max(0, budget - len(DELIMITER_START) - 1 - len(marker))
    middle = body[:keep].rstrip()
    if middle:
        return DELIMITER_START + "\n" + middle + marker
    return DELIMITER_START + marker


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
    custom_instructions = sanitize_custom_instructions(
        payload.get("custom_instructions", "") or ""
    )

    project_root = resolve_project_root(cwd)
    claude_md_path = project_root / "CLAUDE.md"
    project = str(project_root)

    git_context = gather_git_context(project_root)
    reminders = load_reminders()
    recovery_section = build_recovery_section(
        git_context, reminders, custom_instructions
    )

    branch = git_context.get("branch") or "no-git"
    modified = git_context.get("modified_files") or ""
    modified_count = len([f for f in modified.split("\n") if f.strip()]) if modified else 0
    detail_base = f"branch={branch} in_progress_files={modified_count}"

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
