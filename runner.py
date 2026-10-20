import json
import re
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from report import generate_report


def run():
    if len(sys.argv) < 3:
        print("Usage: SOURCE WORKFLOW [EVENT [ACT_ARGS...]]")
        print("  SOURCE  https://github.com/owner/repo, or a mounted directory such as /repo")
        print("  EVENT   push (default), pull_request, workflow_dispatch, ...")
        print("  ACT_ARGS  extra flags passed to act, e.g. --matrix os:ubuntu-latest")
        sys.exit(2)

    source = sys.argv[1]
    workflow = sys.argv[2]
    event = sys.argv[3] if len(sys.argv) > 3 else "push"
    act_args = sys.argv[4:]

    # A local directory is used in place; anything else must be a GitHub URL.
    local = Path(source)
    if local.is_absolute() and local.is_dir():
        repo_url = None
    else:
        repo_url = source
        parsed = urlparse(repo_url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "github.com"
            or not parsed.path.strip("/")
        ):
            sys.exit(
                "Expected an HTTPS github.com repository URL "
                "or an absolute path to a mounted directory"
            )

    if not re.fullmatch(r"[a-z_]+", event):
        sys.exit("Invalid event name")

    # Prevent absolute paths and traversal outside the repository.
    path = Path(workflow)
    if (
        path.is_absolute()
        or ".." in path.parts
        or not workflow.startswith(".github/workflows/")
        or path.suffix not in (".yml", ".yaml")
    ):
        sys.exit("Invalid workflow path")

    out = Path("/reports")
    out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        if repo_url is None:
            repo = local
        else:
            repo = Path(tmp) / "repo"
            subprocess.run(
                ["git", "clone", "--depth", "1",
                 "--", repo_url, str(repo)],
                check=True,
                timeout=180,
            )

        target = (repo / workflow).resolve()
        if not target.is_relative_to(repo.resolve()) or not target.is_file():
            sys.exit("Workflow not found")

        # act finds its own address by routing towards the internet, which
        # fails offline; give it this container's address instead.
        addr = socket.gethostbyname(socket.gethostname())

        cmd = [
            "act", event,
            "-W", workflow,
            "--json",
            "--rm",
            "--container-daemon-socket",
            "/var/run/docker.sock",
            "-P", "ubuntu-latest=catthehacker/ubuntu:act-latest",
            "-P", "ubuntu-24.04=catthehacker/ubuntu:act-latest",
            "-P", "ubuntu-22.04=catthehacker/ubuntu:act-22.04",
            # Lets actions/upload-artifact work; files land in the reports dir.
            "--artifact-server-path", str(out / "artifacts"),
            "--artifact-server-addr", addr,
            "--cache-server-addr", addr,
            *act_args,
        ]

        started = datetime.now(timezone.utc)
        start = time.monotonic()

        # Collect output even when the workflow fails.
        with (out / "workflow.log").open(
            "w", encoding="utf-8"
        ) as log:
            proc = subprocess.run(
                cmd,
                cwd=repo,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )

        duration = time.monotonic() - start

        summary = {
            "repository": repo_url or source,
            "workflow": workflow,
            "event": event,
            "started": started.isoformat(),
            "duration_seconds": round(duration, 2),
            "exit_code": proc.returncode,
            "status": (
                "passed" if proc.returncode == 0 else "failed"
            ),
        }

        (out / "summary.json").write_text(
            json.dumps(summary, indent=2),
            encoding="utf-8",
        )

        generate_report(
            summary,
            out / "workflow.log",
            out / "report.html",
        )

        print(f"Report: {out / 'report.html'}")
        sys.exit(proc.returncode)


if __name__ == "__main__":
    run()
