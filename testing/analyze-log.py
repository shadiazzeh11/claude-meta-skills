#!/usr/bin/env python3
"""
analyze-log.py — summarize hook fires from ~/.claude/meta-skills-log.jsonl.

Usage:
  ./analyze-log.py                   # summary for last 7 days
  ./analyze-log.py --days 14         # last N days
  ./analyze-log.py --real-only       # restrict summaries to real dogfood entries
  ./analyze-log.py --log <path>      # read a different JSONL log (default: ~/.claude/meta-skills-log.jsonl)
  ./analyze-log.py --format markdown # output format: text, json, or markdown
  ./analyze-log.py --output report.md # write the selected format to a file
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
    output_format = "text"
    output_path = None
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
        elif a == "--format":
            if i + 1 >= len(args):
                print("Error: --format requires one of: text, json, markdown", file=sys.stderr)
                sys.exit(1)
            output_format = args[i + 1]
            if output_format not in ("text", "json", "markdown"):
                print(
                    f"Error: --format expects text, json, or markdown; got '{output_format}'",
                    file=sys.stderr,
                )
                sys.exit(1)
            i += 2
        elif a == "--output":
            if i + 1 >= len(args):
                print("Error: --output requires a path", file=sys.stderr)
                sys.exit(1)
            output_path = Path(args[i + 1])
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
    return days, redact, real_only, log_path, output_format, output_path


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


def sorted_action_breakdown(actions):
    return [
        {"action": action, "count": count}
        for action, count in sorted(actions.items(), key=lambda x: -x[1])
    ]


def summarize_report(
    *,
    days,
    redact,
    real_only,
    log_path,
    by_hook_action,
    by_project,
    by_file,
    by_classification,
    real_session_stats,
    real_hook_counts,
    total,
    parse_errors,
    timestamp_errors,
):
    home = str(Path.home())

    hooks = []
    for hook in sorted(by_hook_action.keys()):
        actions = by_hook_action[hook]
        hooks.append(
            {
                "hook": hook,
                "count": sum(actions.values()),
                "actions": sorted_action_breakdown(actions),
            }
        )

    classifications = {label: by_classification.get(label, 0) for label in CLASS_ORDER}
    classification_total = sum(classifications.values())
    real_count = classifications.get(CLASS_REAL, 0)
    non_real_count = classification_total - real_count

    observed_hooks = [h for h in EXPECTED_HOOKS if real_hook_counts.get(h, 0)]
    unexpected_hooks = sorted(set(real_hook_counts) - set(EXPECTED_HOOKS))
    missing_hooks = [h for h in EXPECTED_HOOKS if not real_hook_counts.get(h, 0)]

    sessions = []
    sorted_sessions = sorted(
        real_session_stats.items(),
        key=lambda x: (-x[1]["count"], x[1]["first_ts"], x[0]),
    )[:10]
    for sid, stats in sorted_sessions:
        project = ""
        if stats["projects"]:
            project = max(stats["projects"].items(), key=lambda x: (x[1], x[0]))[0]
        sessions.append(
            {
                "session_id": sid,
                "session_id_short": sid[:8] + "…",
                "count": stats["count"],
                "hooks": sorted(stats["hooks"].keys()),
                "hook_counts": dict(sorted(stats["hooks"].items())),
                "project": redact_path(project, home) if redact else project,
                "first_ts": stats["first_ts"],
                "last_ts": stats["last_ts"],
            }
        )

    files = []
    for file_path, hook_counts in sorted(
        by_file.items(), key=lambda x: -sum(x[1].values())
    )[:10]:
        files.append(
            {
                "path": redact_path(file_path, home) if redact else file_path,
                "count": sum(hook_counts.values()),
                "hooks": sorted(hook_counts.keys()),
                "hook_counts": dict(sorted(hook_counts.items())),
            }
        )

    projects = []
    for project, count in sorted(by_project.items(), key=lambda x: -x[1])[:10]:
        projects.append(
            {
                "path": redact_path(project, home) if redact else project,
                "count": count,
            }
        )

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "days": days,
        "filter": "real dogfood only" if real_only else "all",
        "redacted": redact,
        "log_path": redact_path(str(log_path), home) if redact else str(log_path),
        "total_fires": total,
        "hook_count": len(by_hook_action),
        "hooks": hooks,
        "classification_totals": classifications,
        "classification_total": classification_total,
        "real_dogfood_count": real_count,
        "non_real_count": non_real_count,
        "real_session_count": len(real_session_stats),
        "observed_real_hooks": [
            {"hook": hook, "count": real_hook_counts[hook]} for hook in observed_hooks
        ],
        "unexpected_real_hooks": [
            {"hook": hook, "count": real_hook_counts[hook]} for hook in unexpected_hooks
        ],
        "missing_real_hooks": missing_hooks,
        "real_sessions": sessions,
        "top_files": files,
        "top_projects": projects,
        "parse_errors": parse_errors,
        "timestamp_errors": timestamp_errors,
    }


def format_action_breakdown(actions):
    return ", ".join(f"{a['count']} {a['action']}" for a in actions)


def format_text_report(report):
    lines = [f"Hook fire summary (last {report['days']} days):"]
    if report["filter"] == "real dogfood only":
        lines.extend(["", "Filter: real dogfood only"])
    lines.append("")

    if not report["hooks"]:
        lines.append("  (no fires in window)")
    else:
        for hook in report["hooks"]:
            lines.append(
                f"  {hook['hook']}: {hook['count']} fires "
                f"({format_action_breakdown(hook['actions'])})"
            )
    lines.append("")
    lines.append(f"Total: {report['total_fires']} fires across {report['hook_count']} hooks")
    if report["parse_errors"]:
        lines.append(f"  (skipped {report['parse_errors']} unparseable lines)")
    if report["timestamp_errors"]:
        lines.append(f"  (skipped {report['timestamp_errors']} lines with invalid timestamps)")
    lines.append("")

    lines.append("Classification totals (all matching log entries, before --real-only display filter):")
    for label in CLASS_ORDER:
        lines.append(f"  {label}: {report['classification_totals'].get(label, 0)} fires")
    lines.append(f"  Real Claude Code sessions: {report['real_session_count']}")
    if report["non_real_count"] and report["filter"] != "real dogfood only":
        lines.append(
            f"  Noise note: {report['non_real_count']} / {report['classification_total']} "
            "fires are non-real. Use --real-only for dogfood evidence."
        )
    elif report["non_real_count"] and report["filter"] == "real dogfood only":
        lines.append(f"  Display filter removed {report['non_real_count']} non-real fires.")
    lines.append("")

    lines.append("Real dogfood hook coverage:")
    observed_labels = [
        f"{item['hook']} ({item['count']})" for item in report["observed_real_hooks"]
    ]
    observed_labels.extend(
        f"{item['hook']} ({item['count']}, unexpected)"
        for item in report["unexpected_real_hooks"]
    )
    if observed_labels:
        lines.append(f"  Observed real hooks: {', '.join(observed_labels)}")
    else:
        lines.append("  Observed real hooks: (none)")
    if report["missing_real_hooks"]:
        lines.append(f"  Missing real-session evidence: {', '.join(report['missing_real_hooks'])}")
    else:
        lines.append("  Missing real-session evidence: (none)")
    lines.append("")

    if report["real_sessions"]:
        lines.append("Real dogfood sessions:")
        for session in report["real_sessions"]:
            hooks = ", ".join(session["hooks"])
            project_text = f", project={session['project']}" if session["project"] else ""
            if session["first_ts"] == session["last_ts"]:
                time_text = f", time={session['first_ts']}"
            else:
                time_text = f", time={session['first_ts']}..{session['last_ts']}"
            hook_word = "hook" if len(session["hooks"]) == 1 else "hooks"
            fire_word = "fire" if session["count"] == 1 else "fires"
            lines.append(
                f"  {session['session_id_short']} — {session['count']} {fire_word}, "
                f"{len(session['hooks'])} {hook_word} ({hooks}){project_text}{time_text}"
            )
    lines.append("")

    if report["top_files"]:
        lines.append("Top triggered files:")
        for item in report["top_files"]:
            lines.append(
                f"  {item['path']} — {item['count']} fires ({','.join(item['hooks'])})"
            )
        lines.append("")

    if report["top_projects"]:
        lines.append("Projects:")
        for item in report["top_projects"]:
            lines.append(f"  {item['path']} — {item['count']} fires")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def markdown_table(headers, rows):
    def cell(value):
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        "| " + " | ".join(cell(header) for header in headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(cell(value) for value in row) + " |")
    return "\n".join(lines)


def format_markdown_report(report):
    lines = [
        "# Meta-skills Hook Fire Report",
        "",
        f"- Window: last {report['days']} days",
        f"- Filter: {report['filter']}",
        f"- Generated: {report['generated_at']}",
        f"- Log: `{report['log_path']}`",
        f"- Total displayed fires: {report['total_fires']}",
        f"- Real Claude Code sessions: {report['real_session_count']}",
        "",
        "## Hook Summary",
        "",
    ]

    if report["hooks"]:
        lines.append(
            markdown_table(
                ["Hook", "Fires", "Actions"],
                [
                    [
                        item["hook"],
                        item["count"],
                        format_action_breakdown(item["actions"]),
                    ]
                    for item in report["hooks"]
                ],
            )
        )
    else:
        lines.append("(no fires in window)")
    lines.extend(["", "## Classification", ""])
    lines.append(
        markdown_table(
            ["Bucket", "Fires"],
            [[label, report["classification_totals"].get(label, 0)] for label in CLASS_ORDER],
        )
    )
    if report["non_real_count"] and report["filter"] == "all":
        lines.append("")
        lines.append(
            f"Noise note: {report['non_real_count']} / {report['classification_total']} "
            "fires are non-real. Use `--real-only` for dogfood evidence."
        )
    elif report["non_real_count"]:
        lines.append("")
        lines.append(f"Display filter removed {report['non_real_count']} non-real fires.")

    lines.extend(["", "## Real Dogfood Coverage", ""])
    observed = ", ".join(
        f"{item['hook']} ({item['count']})" for item in report["observed_real_hooks"]
    )
    if report["unexpected_real_hooks"]:
        unexpected = ", ".join(
            f"{item['hook']} ({item['count']}, unexpected)"
            for item in report["unexpected_real_hooks"]
        )
        observed = ", ".join(filter(None, [observed, unexpected]))
    lines.append(f"- Observed real hooks: {observed or '(none)'}")
    if report["missing_real_hooks"]:
        lines.append(f"- Missing real-session evidence: {', '.join(report['missing_real_hooks'])}")
    else:
        lines.append("- Missing real-session evidence: (none)")

    if report["real_sessions"]:
        lines.extend(["", "## Real Dogfood Sessions", ""])
        lines.append(
            markdown_table(
                ["Session", "Fires", "Hooks", "Project", "Time"],
                [
                    [
                        session["session_id_short"],
                        session["count"],
                        ", ".join(session["hooks"]),
                        f"`{session['project']}`" if session["project"] else "",
                        session["first_ts"]
                        if session["first_ts"] == session["last_ts"]
                        else f"{session['first_ts']}..{session['last_ts']}",
                    ]
                    for session in report["real_sessions"]
                ],
            )
        )

    if report["top_files"]:
        lines.extend(["", "## Top Triggered Files", ""])
        lines.append(
            markdown_table(
                ["Path", "Fires", "Hooks"],
                [
                    [f"`{item['path']}`", item["count"], ", ".join(item["hooks"])]
                    for item in report["top_files"]
                ],
            )
        )

    if report["top_projects"]:
        lines.extend(["", "## Projects", ""])
        lines.append(
            markdown_table(
                ["Project", "Fires"],
                [[f"`{item['path']}`", item["count"]] for item in report["top_projects"]],
            )
        )

    lines.extend(
        [
            "",
            "## Caveats",
            "",
            "- The log records hook fires, not whether Claude self-corrected afterward.",
            "- Real dogfood evidence is lifecycle evidence, not production false-positive rate.",
            "- `detail` fields contain metadata only, but paths can still identify projects; use `--redact` before sharing.",
        ]
    )
    if report["parse_errors"] or report["timestamp_errors"]:
        lines.extend(["", "## Skipped Lines", ""])
        if report["parse_errors"]:
            lines.append(f"- Unparseable JSON lines: {report['parse_errors']}")
        if report["timestamp_errors"]:
            lines.append(f"- Invalid timestamps: {report['timestamp_errors']}")

    return "\n".join(lines).rstrip() + "\n"


def format_report(report, output_format):
    if output_format == "text":
        return format_text_report(report)
    if output_format == "json":
        return json.dumps(report, indent=2, sort_keys=True) + "\n"
    if output_format == "markdown":
        return format_markdown_report(report)
    raise ValueError(f"unsupported format: {output_format}")


def emit_output(content, output_path):
    if output_path is None:
        sys.stdout.write(content)
        return
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(content)
    except OSError as exc:
        print(f"Error: couldn't write report to {output_path}: {exc}", file=sys.stderr)
        sys.exit(1)


def format_missing_log(log_path, output_format, redact):
    home = str(Path.home())
    display_path = redact_path(str(log_path), home) if redact else str(log_path)
    message = f"No log file at {display_path}."
    hint = "Logging activates the first time a hook fires after install."
    if output_format == "json":
        return json.dumps(
            {
                "error": "log_not_found",
                "log_path": display_path,
                "message": message,
                "hint": hint,
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
    if output_format == "markdown":
        return f"# Meta-skills Hook Fire Report\n\n{message}\n\n{hint}\n"
    return f"{message}\n{hint}\n"


def main():
    days, redact, real_only, log_path, output_format, output_path = parse_args()

    if not log_path.exists():
        emit_output(format_missing_log(log_path, output_format, redact), output_path)
        return 0

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

    report = summarize_report(
        days=days,
        redact=redact,
        real_only=real_only,
        log_path=log_path,
        by_hook_action=by_hook_action,
        by_project=by_project,
        by_file=by_file,
        by_classification=by_classification,
        real_session_stats=real_session_stats,
        real_hook_counts=real_hook_counts,
        total=total,
        parse_errors=parse_errors,
        timestamp_errors=timestamp_errors,
    )
    emit_output(format_report(report, output_format), output_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
