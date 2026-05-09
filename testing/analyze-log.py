#!/usr/bin/env python3
"""
analyze-log.py — summarize hook fires from ~/.claude/meta-skills-log.jsonl.

Usage:
  ./analyze-log.py                   # summary for last 7 days
  ./analyze-log.py --days 14         # last N days
  ./analyze-log.py --real-only       # restrict summaries to real dogfood entries
  ./analyze-log.py --log <path>      # read a different JSONL log (default: ~/.claude/meta-skills-log.jsonl)
  ./analyze-log.py --redact          # redact home prefix to ~ for safer sharing
  ./analyze-log.py --help

The log is a privacy-conscious append-only JSONL where each line records one
hook fire (block, warn, modify, create, skip-*). It contains paths and pattern
names but no file content, no diff snippets, and no test output.

Each entry is classified so dogfood progress is not conflated with manual
proof or harness/validation noise:

  - real dogfood:       UUID-shaped session_id from a live Claude Code
                        session, with no harness or manual indicators.
  - manual/synthetic:   session_id == "manual-test" (manual stdin invocations
                        used to prove hook logic outside Claude Code).
  - harness/validation: session_id == "test-session", project or file path
                        under validation/test-cases/, or project under the
                        harness stub root /Users/test/project.
  - unknown:            session_id missing/empty or not in any known shape.

macOS /private/tmp paths are normalized to /tmp before grouping so the same
disposable project does not appear under two project keys.
"""
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

DEFAULT_LOG_PATH = Path.home() / ".claude" / "meta-skills-log.jsonl"

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

CLASS_REAL = "real dogfood"
CLASS_MANUAL = "manual/synthetic"
CLASS_HARNESS = "harness/validation"
CLASS_UNKNOWN = "unknown"

CLASS_ORDER = [CLASS_REAL, CLASS_MANUAL, CLASS_HARNESS, CLASS_UNKNOWN]


def parse_args():
    days = 7
    redact = False
    real_only = False
    log_path = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--days":
            if i + 1 >= len(args):
                print("Error: --days requires a number", file=sys.stderr)
                sys.exit(1)
            try:
                days = int(args[i + 1])
            except ValueError:
                print(f"Error: --days expects an integer, got '{args[i + 1]}'", file=sys.stderr)
                sys.exit(1)
            i += 2
        elif a == "--redact":
            redact = True
            i += 1
        elif a == "--real-only":
            real_only = True
            i += 1
        elif a == "--log":
            if i + 1 >= len(args):
                print("Error: --log requires a path", file=sys.stderr)
                sys.exit(1)
            log_path = Path(args[i + 1])
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        else:
            print(f"Unknown argument: {a}", file=sys.stderr)
            print("Use --help for usage.", file=sys.stderr)
            sys.exit(1)
    if log_path is None:
        log_path = DEFAULT_LOG_PATH
    return days, redact, real_only, log_path


def redact_path(p, home):
    if p and p.startswith(home):
        return "~" + p[len(home):]
    return p


def canonicalize_path(p):
    """Normalize macOS /private/tmp paths to /tmp. No-op for other paths."""
    if not p:
        return p
    if p == "/private/tmp":
        return "/tmp"
    if p.startswith("/private/tmp/"):
        return "/tmp/" + p[len("/private/tmp/"):]
    return p


def canonicalize_file(p):
    """Canonicalize absolute paths only; relative paths are returned unchanged."""
    if not p:
        return p
    if not os.path.isabs(p):
        return p
    return canonicalize_path(p)


def extract_file_from_detail(detail):
    """Pull file=... from detail field. Returns None if not present."""
    for part in detail.split():
        if part.startswith("file="):
            return part[len("file="):]
    return None


def classify(session_id, project, file_path):
    """Classify a log entry. file_path may be None."""
    sid = (session_id or "").strip()

    if sid == "manual-test":
        return CLASS_MANUAL

    if (
        sid == "test-session"
        or "validation/test-cases" in (project or "")
        or (file_path and "validation/test-cases" in file_path)
        or (project or "").startswith("/Users/test/project")
    ):
        return CLASS_HARNESS

    if not sid or not UUID_RE.match(sid):
        return CLASS_UNKNOWN

    return CLASS_REAL


def main():
    days, redact, real_only, log_path = parse_args()

    if not log_path.exists():
        print(f"No log file at {log_path}.")
        print("Logging activates the first time a hook fires after install.")
        return 0

    home = str(Path.home())
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")

    by_hook_action = defaultdict(lambda: defaultdict(int))
    by_project = defaultdict(int)
    by_file = defaultdict(lambda: defaultdict(int))
    by_classification = defaultdict(int)
    real_sessions = set()
    total = 0
    parse_errors = 0

    with open(log_path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                parse_errors += 1
                continue
            ts = entry.get("timestamp", "")
            if ts < cutoff_str:
                continue

            hook = entry.get("hook", "unknown")
            action = entry.get("action", "unknown")
            project = canonicalize_path(entry.get("project") or "")
            detail = entry.get("detail", "")
            file_path = canonicalize_file(extract_file_from_detail(detail))

            classification = classify(entry.get("session_id"), project, file_path)
            by_classification[classification] += 1
            if classification == CLASS_REAL:
                sid = (entry.get("session_id") or "").strip()
                if sid:
                    real_sessions.add(sid)

            if real_only and classification != CLASS_REAL:
                continue

            by_hook_action[hook][action] += 1
            if project:
                by_project[project] += 1
            if file_path:
                by_file[file_path][hook] += 1
            total += 1

    print(f"Hook fire summary (last {days} days):")
    if real_only:
        print()
        print("Filter: real dogfood only")
    print()
    if not by_hook_action:
        print("  (no fires in window)")
    else:
        for hook in sorted(by_hook_action.keys()):
            actions = by_hook_action[hook]
            total_for_hook = sum(actions.values())
            action_breakdown = ", ".join(
                f"{n} {a}" for a, n in sorted(actions.items(), key=lambda x: -x[1])
            )
            print(f"  {hook}: {total_for_hook} fires ({action_breakdown})")
    print()
    print(f"Total: {total} fires across {len(by_hook_action)} hooks")
    if parse_errors:
        print(f"  (skipped {parse_errors} unparseable lines)")
    print()

    print("Classification totals (all matching log entries, before --real-only display filter):")
    for label in CLASS_ORDER:
        print(f"  {label}: {by_classification.get(label, 0)} fires")
    print(f"  Real Claude Code sessions: {len(real_sessions)}")
    print()

    if by_file:
        print("Top triggered files:")
        sorted_files = sorted(
            by_file.items(), key=lambda x: -sum(x[1].values())
        )[:10]
        for file_path, hook_counts in sorted_files:
            count = sum(hook_counts.values())
            hook_str = ",".join(sorted(hook_counts.keys()))
            display = redact_path(file_path, home) if redact else file_path
            print(f"  {display} — {count} fires ({hook_str})")
        print()

    if by_project:
        print("Projects:")
        sorted_projects = sorted(by_project.items(), key=lambda x: -x[1])[:10]
        for project, count in sorted_projects:
            display = redact_path(project, home) if redact else project
            print(f"  {display} — {count} fires")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
