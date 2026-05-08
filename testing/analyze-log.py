#!/usr/bin/env python3
"""
analyze-log.py — summarize hook fires from ~/.claude/meta-skills-log.jsonl.

Usage:
  ./analyze-log.py                  # summary for last 7 days
  ./analyze-log.py --days 14        # last N days
  ./analyze-log.py --redact         # redact home prefix to ~ for safer sharing
  ./analyze-log.py --help

The log is a privacy-conscious append-only JSONL where each line records one
hook fire (block, warn, modify, create, skip-*). It contains paths and pattern
names but no file content, no diff snippets, and no test output.
"""
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

LOG_PATH = Path.home() / ".claude" / "meta-skills-log.jsonl"


def parse_args():
    days = 7
    redact = False
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
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        else:
            print(f"Unknown argument: {a}", file=sys.stderr)
            print("Use --help for usage.", file=sys.stderr)
            sys.exit(1)
    return days, redact


def redact_path(p, home):
    if p and p.startswith(home):
        return "~" + p[len(home):]
    return p


def extract_file_from_detail(detail):
    """Pull file=... from detail field. Returns None if not present."""
    for part in detail.split():
        if part.startswith("file="):
            return part[len("file="):]
    return None


def main():
    days, redact = parse_args()

    if not LOG_PATH.exists():
        print(f"No log file at {LOG_PATH}.")
        print("Logging activates the first time a hook fires after install.")
        return 0

    home = str(Path.home())
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")

    by_hook_action = defaultdict(lambda: defaultdict(int))
    by_project = defaultdict(int)
    by_file = defaultdict(lambda: defaultdict(int))
    total = 0
    parse_errors = 0

    with open(LOG_PATH, "r", errors="replace") as f:
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
            project = entry.get("project", "")
            detail = entry.get("detail", "")
            by_hook_action[hook][action] += 1
            if project:
                by_project[project] += 1
            file_path = extract_file_from_detail(detail)
            if file_path:
                by_file[file_path][hook] += 1
            total += 1

    print(f"Hook fire summary (last {days} days):")
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
