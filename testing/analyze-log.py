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

The summary includes real dogfood hook coverage and live-session grouping so it
answers both "what fired?" and "which hooks still lack real-session evidence?"
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
EXPECTED_HOOKS = [
    "edit-drift-detector",
    "construction-gate",
    "silent-file-verifier",
    "completion-verifier",
    "context-recovery",
]


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
    if p and (p == home or p.startswith(home + os.sep)):
        return "~" + p[len(home):]
    return p


def parse_timestamp(ts):
    """Parse an ISO-8601 timestamp into UTC. Returns None when malformed."""
    if not isinstance(ts, str) or not ts:
        return None
    try:
        normalized = ts[:-1] + "+00:00" if ts.endswith("Z") else ts
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


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


def extract_path_from_detail(detail):
    """Pull file=... or path=... from detail. Values may contain spaces."""
    if not detail:
        return None
    for key in ("file", "path"):
        match = re.search(rf"(?<!\S){re.escape(key)}=", detail)
        if not match:
            continue
        start = match.end()
        next_key = re.search(r"\s+[A-Za-z_][A-Za-z0-9_-]*=", detail[start:])
        end = start + next_key.start() if next_key else len(detail)
        value = detail[start:end].strip()
        if value:
            return value
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

    by_hook_action = defaultdict(lambda: defaultdict(int))
    by_project = defaultdict(int)
    by_file = defaultdict(lambda: defaultdict(int))
    by_classification = defaultdict(int)
    real_session_stats = {}
    real_hook_counts = defaultdict(int)
    total = 0
    parse_errors = 0
    timestamp_errors = 0

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
            ts_dt = parse_timestamp(entry.get("timestamp", ""))
            if ts_dt is None:
                timestamp_errors += 1
                continue
            if ts_dt < cutoff:
                continue
            ts = ts_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

            hook = entry.get("hook", "unknown")
            action = entry.get("action", "unknown")
            project = canonicalize_path(entry.get("project") or "")
            detail = entry.get("detail", "")
            file_path = canonicalize_file(extract_path_from_detail(detail))

            classification = classify(entry.get("session_id"), project, file_path)
            by_classification[classification] += 1
            if classification == CLASS_REAL:
                sid = (entry.get("session_id") or "").strip()
                if sid:
                    stats = real_session_stats.setdefault(
                        sid,
                        {
                            "count": 0,
                            "hooks": defaultdict(int),
                            "projects": defaultdict(int),
                            "first_ts": ts,
                            "last_ts": ts,
                        },
                    )
                    stats["count"] += 1
                    stats["hooks"][hook] += 1
                    if project:
                        stats["projects"][project] += 1
                    if ts < stats["first_ts"]:
                        stats["first_ts"] = ts
                    if ts > stats["last_ts"]:
                        stats["last_ts"] = ts
                    real_hook_counts[hook] += 1

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
    if timestamp_errors:
        print(f"  (skipped {timestamp_errors} lines with invalid timestamps)")
    print()

    print("Classification totals (all matching log entries, before --real-only display filter):")
    for label in CLASS_ORDER:
        print(f"  {label}: {by_classification.get(label, 0)} fires")
    classification_total = sum(by_classification.values())
    real_count = by_classification.get(CLASS_REAL, 0)
    non_real_count = classification_total - real_count
    print(f"  Real Claude Code sessions: {len(real_session_stats)}")
    if non_real_count and not real_only:
        print(
            f"  Noise note: {non_real_count} / {classification_total} fires are non-real. "
            "Use --real-only for dogfood evidence."
        )
    elif non_real_count and real_only:
        print(f"  Display filter removed {non_real_count} non-real fires.")
    print()

    print("Real dogfood hook coverage:")
    observed_hooks = [h for h in EXPECTED_HOOKS if real_hook_counts.get(h, 0)]
    unexpected_hooks = sorted(set(real_hook_counts) - set(EXPECTED_HOOKS))
    observed_labels = [f"{h} ({real_hook_counts[h]})" for h in observed_hooks]
    observed_labels.extend(f"{h} ({real_hook_counts[h]}, unexpected)" for h in unexpected_hooks)
    if observed_labels:
        print(f"  Observed real hooks: {', '.join(observed_labels)}")
    else:
        print("  Observed real hooks: (none)")
    missing_hooks = [h for h in EXPECTED_HOOKS if not real_hook_counts.get(h, 0)]
    if missing_hooks:
        print(f"  Missing real-session evidence: {', '.join(missing_hooks)}")
    else:
        print("  Missing real-session evidence: (none)")
    print()

    if real_session_stats:
        print("Real dogfood sessions:")
        sorted_sessions = sorted(
            real_session_stats.items(),
            key=lambda x: (-x[1]["count"], x[1]["first_ts"], x[0]),
        )[:10]
        for sid, stats in sorted_sessions:
            hooks = ", ".join(sorted(stats["hooks"].keys()))
            project = ""
            if stats["projects"]:
                project = max(stats["projects"].items(), key=lambda x: (x[1], x[0]))[0]
            display_project = redact_path(project, home) if redact else project
            project_text = f", project={display_project}" if display_project else ""
            if stats["first_ts"] == stats["last_ts"]:
                time_text = f", time={stats['first_ts']}"
            else:
                time_text = f", time={stats['first_ts']}..{stats['last_ts']}"
            hook_word = "hook" if len(stats["hooks"]) == 1 else "hooks"
            fire_word = "fire" if stats["count"] == 1 else "fires"
            print(
                f"  {sid[:8]}… — {stats['count']} {fire_word}, "
                f"{len(stats['hooks'])} {hook_word} ({hooks}){project_text}{time_text}"
            )
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
