#!/usr/bin/env python3
"""
context-recovery hook for Claude Code.

PreCompact hook. Captures session context (git state + static reminders)
and writes a recovery section to CLAUDE.md before compaction. After
compaction, CLAUDE.md auto-reloads with the recovery context preserved.

Architecture: PreCompact + CLAUDE.md modification. Chosen because the
SessionStart:compact stdout-injection pathway is broken (issue #15174);
CLAUDE.md modification is the verified working path for post-compaction
context preservation. Current Claude Code docs list PostCompact, but this
hook intentionally writes before compaction via the dogfooded PreCompact
path.

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
