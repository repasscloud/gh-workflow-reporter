import html
import json
from collections import defaultdict
from datetime import datetime
from pathlib import Path


def escape(value):
    return html.escape(str(value), quote=True)


def parse_logs(log_path):
    jobs = defaultdict(list)

    for line in Path(log_path).read_text(
        encoding="utf-8", errors="replace"
    ).splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            event = {"msg": line}

        if not isinstance(event, dict):
            event = {"msg": str(event)}

        job = (
            event.get("job")
            or event.get("jobID")
            or event.get("job_id")
            or event.get("prefix")
            or "General"
        )

        jobs[str(job)].append(event)

    return jobs


def generate_report(summary, log_path, output_path):
    jobs = parse_logs(log_path)

    sections = []
    total_errors = 0

    for job, events in jobs.items():
        rows = []

        for event in events:
            level = str(event.get("level", "info")).lower()
            message = event.get(
                "msg", event.get("message", "")
            )
            timestamp = event.get("time", "")

            if level in ("error", "fatal", "panic"):
                total_errors += 1

            css = "error" if level in (
                "error", "fatal", "panic"
            ) else ""

            rows.append(
                f'<div class="entry {css}">'
                f'<span class="timestamp">{escape(timestamp)}</span> '
                f'<span class="level">{escape(level)}</span> '
                f'{escape(message)}'
                f'</div>'
            )

        sections.append(
            f'<details open>'
            f'<summary>{escape(job)} '
            f'({len(events)} events)</summary>'
            f'<div class="logs">{"".join(rows)}</div>'
            f'</details>'
        )

    status = summary["status"]
    color = "#16a34a" if status == "passed" else "#dc2626"

    page = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GitHub Workflow Report</title>
<style>
body {
  font-family: system-ui, sans-serif;
  background: #f5f6f8;
  color: #18202b;
  margin: 0;
  padding: 32px;
}
main { max-width: 1100px; margin: auto; }
header, details, .stat {
  background: white;
  border: 1px solid #e1e4e8;
  border-radius: 10px;
  padding: 20px;
  margin-bottom: 16px;
}
h1 { margin: 0 0 12px; }
.meta { overflow-wrap: anywhere; }
.stats { display: flex; gap: 12px; flex-wrap: wrap; }
.stat { flex: 1; min-width: 140px; }
.stat strong { display: block; font-size: 24px; }
summary { cursor: pointer; font-weight: 600; }
.logs {
  font: 12px/1.6 monospace;
  overflow-x: auto;
  margin-top: 16px;
}
.entry {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  padding: 3px 5px;
  border-bottom: 1px solid #eee;
}
.entry.error { color: #b91c1c; background: #fff1f2; }
.timestamp { color: #64748b; }
.level { font-weight: bold; }
input {
  width: 100%; box-sizing: border-box;
  padding: 12px; margin: 16px 0;
  border: 1px solid #ccd2da; border-radius: 8px;
}
</style>
</head>
<body>
<main>
<header>
<h1>Workflow execution report</h1>
<div class="meta">REPOSITORY</div>
<p>WORKFLOW</p>
<h2 style="color:STATUS_COLOR">STATUS</h2>
</header>
<div class="stats">
<div class="stat">Duration<strong>DURATION s</strong></div>
<div class="stat">Log groups<strong>JOBS</strong></div>
<div class="stat">Error events<strong>ERRORS</strong></div>
<div class="stat">Exit code<strong>EXIT_CODE</strong></div>
</div>
<h2>Execution log</h2>
<input id="search" placeholder="Filter logs by message...">
SECTIONS
</main>
<script>
document.getElementById("search").addEventListener(
  "input", function () {
    const term = this.value.toLowerCase();
    document.querySelectorAll(".entry").forEach(el => {
      el.hidden = !el.textContent.toLowerCase().includes(term);
    });
  }
);
</script>
</body>
</html>"""

    replacements = {
        "REPOSITORY": escape(summary["repository"]),
        "WORKFLOW": escape(summary["workflow"]),
        "STATUS_COLOR": color,
        "STATUS": escape(status.upper()),
        "DURATION": escape(summary["duration_seconds"]),
        "JOBS": str(len(jobs)),
        "ERRORS": str(total_errors),
        "EXIT_CODE": str(summary["exit_code"]),
        "SECTIONS": "\n".join(sections),
    }

    # Replace longer placeholders first to avoid collisions.
    for key in sorted(replacements, key=len, reverse=True):
        page = page.replace(key, replacements[key])

    Path(output_path).write_text(page, encoding="utf-8")
