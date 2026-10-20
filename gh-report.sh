#!/usr/bin/env bash
# Run a GitHub Actions workflow from a local repository (or git worktree) with
# act, inside the gh-workflow-reporter Docker image, and write an HTML report.
#
# USAGE
#   gh-report.sh [-C DIR] [-o REPORTS_DIR] [-O] WORKFLOW [EVENT [ACT_ARGS...]]
#   gh-report.sh -h
#
#   Options (-C, -o, -O) go BEFORE the workflow path. Anything after EVENT is
#   passed straight to act; to pass act flags you must also give EVENT.
#
# ARGUMENTS
#   WORKFLOW        workflow file, relative to the repository root (even with
#                   -C), e.g. .github/workflows/ci.yml
#   EVENT           event to simulate (default: push). Common values:
#                     push               honours on.push branch/path filters
#                     pull_request       honours on.pull_request filters
#                     workflow_dispatch  manual run; ignores branch filters
#   ACT_ARGS        extra act flags, see ACT FLAGS below
#
# OPTIONS
#   -C DIR          repository or worktree to run (default: current directory)
#   -o REPORTS_DIR  where the report is written (default: ./reports). Use a
#                   path outside the repository, or add reports/ to .gitignore
#   -O              offline: reuse cached actions and local images only
#                   (adds --action-offline-mode --pull=false). Needs one
#                   earlier online run to fill the action cache
#   -h              show this help
#
# ENVIRONMENT
#   GH_REPORTER_IMAGE           image to run (default: gh-workflow-reporter)
#   GH_REPORTER_CACHE_VOLUME    volume caching act's downloaded actions
#                               (default: gh-workflow-reporter-cache)
#   GH_REPORTER_ALLOW_PARALLEL  set to 1 to start while another run is active
#
# OUTPUT (in REPORTS_DIR)
#   report.html     status, duration, errors and a searchable log per job
#   summary.json    the same summary as JSON
#   workflow.log    raw act output, one JSON object per line
#   artifacts/      files uploaded with actions/upload-artifact
#   The exit code is the workflow's exit code (0 = passed).
#
# ACT FLAGS (put after EVENT)
#   --matrix KEY:VALUE          keep only matrix entries where KEY=VALUE; works
#                               with include: lists; repeatable.
#                               e.g. --matrix os:ubuntu-latest (skip Win/macOS)
#   -j JOB_ID                   run one job (key under jobs:) plus its needs:
#   --input NAME=VALUE          workflow_dispatch input
#   --env NAME=VALUE            environment variable for every job
#   -s NAME=VALUE               secret (secrets.NAME); none are passed by default
#   --var NAME=VALUE            variable (vars.NAME)
#   --secret-file PATH          secrets file, relative to the repo root
#                               (act reads ./.secrets automatically if present)
#   --env-file PATH             env file, relative to the repo root
#                               (act reads ./.env automatically if present)
#   -P LABEL=IMAGE              image for a runs-on label, e.g.
#                               -P ubuntu-latest=gh-workflow-reporter-dotnet
#   --pull=false                don't pull job images; required for local-only
#                               images such as the .NET runner image (-O sets it)
#   --container-options "..."   extra docker run options for job containers,
#                               e.g. "-v gh-workflow-reporter-nuget:/root/.nuget/packages"
#   --container-architecture linux/amd64
#                               run jobs as amd64 on Apple Silicon (emulated)
#   All act flags: docker run --rm --entrypoint act gh-workflow-reporter --help
#
# TESTCONTAINERS (tests that start their own database containers)
#   --env TESTCONTAINERS_RYUK_DISABLED=true
#   --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal
#   Without these, tests fail with "ResourceReaperException: Initialization has
#   been cancelled". host.docker.internal is Docker Desktop only; on Linux use
#   an address of the Docker host instead.
#
# .NET AND OFFLINE RUNS
#   Build the .NET runner image (SDK preinstalled) once:
#     docker build -t gh-workflow-reporter-dotnet \
#       --build-arg DOTNET_SDK_VERSIONS="10.0.402" \
#       --build-arg DOTNET_RUNTIME_VERSIONS="10.0.13" runner-images/dotnet
#   Use it with: -P ubuntu-latest=gh-workflow-reporter-dotnet --pull=false
#   Offline, actions/setup-dotnet always fails (it looks up the version online),
#   so skip it under act in the workflow:  if: ${{ !env.ACT }}
#   Keep NuGet packages between runs:
#     --container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages"
#   Offline, add --env NuGetAudit=false, or NuGet warning NU1900 fails builds
#   that treat warnings as errors.
#
# EXAMPLES
#   From inside a repository:
#     gh-report.sh .github/workflows/ci.yml
#     gh-report.sh .github/workflows/ci.yml pull_request
#     gh-report.sh .github/workflows/release.yml workflow_dispatch --input version=1.2.3
#
#   A worktree, Linux matrix entries of one job, reports outside the repo:
#     gh-report.sh -C ~/worktrees/my-project -o ~/gh-reports/my-project \
#       .github/workflows/ci.yml workflow_dispatch \
#       --matrix os:ubuntu-latest -j build-test
#
#   A .NET project with Testcontainers, online (also fills the caches):
#     gh-report.sh -C ~/worktrees/my-project -o ~/gh-reports/my-project \
#       .github/workflows/ci.yml workflow_dispatch \
#       --matrix os:ubuntu-latest -j build-test \
#       -P ubuntu-latest=gh-workflow-reporter-dotnet --pull=false \
#       --container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages" \
#       --env TESTCONTAINERS_RYUK_DISABLED=true \
#       --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal
#
#   The same, offline:
#     gh-report.sh -O -C ~/worktrees/my-project -o ~/gh-reports/my-project \
#       .github/workflows/ci.yml workflow_dispatch \
#       --matrix os:ubuntu-latest -j build-test \
#       -P ubuntu-latest=gh-workflow-reporter-dotnet \
#       --container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages" \
#       --env NuGetAudit=false \
#       --env TESTCONTAINERS_RYUK_DISABLED=true \
#       --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal
#
# NOTES
#   - The repository is mounted read-only; uncommitted changes are included.
#   - Git worktrees work: the main repository's git directory is mounted too.
#   - Only Linux jobs run. Windows and macOS jobs are skipped by act.
#   - One run at a time: act reuses job container names, so a second run of the
#     same job deletes the first run's container (exit code 137, "RWLayer ... is
#     unexpectedly nil"). This script refuses to start while another run is
#     active; see GH_REPORTER_ALLOW_PARALLEL.
#   - Images used by default: catthehacker/ubuntu:act-latest (ubuntu-latest,
#     ubuntu-24.04) and catthehacker/ubuntu:act-22.04 (ubuntu-22.04).
#   - Clean up caches: docker volume rm gh-workflow-reporter-cache gh-workflow-reporter-nuget
set -euo pipefail

image="${GH_REPORTER_IMAGE:-gh-workflow-reporter}"
repo_dir="$PWD"
reports_dir="$PWD/reports"
offline_args=()

# Print the comment block at the top of this file.
usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

while getopts "C:o:Oh" opt; do
  case "$opt" in
    C) repo_dir="$OPTARG" ;;
    o) reports_dir="$OPTARG" ;;
    O) offline_args=(--action-offline-mode --pull=false) ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || usage

workflow="$1"
event="${2:-push}"

# act names job containers after the workflow and job only, so a second run of
# the same job removes the first run's container mid-step (exit code 137).
if [ "${GH_REPORTER_ALLOW_PARALLEL:-}" != "1" ]; then
  running="$(docker ps --filter "ancestor=$image" --format '{{.Names}}  (started {{.RunningFor}})')"
  if [ -n "$running" ]; then
    echo "Another gh-workflow-reporter run is active:" >&2
    echo "$running" | sed 's/^/  /' >&2
    echo "Wait for it to finish, or set GH_REPORTER_ALLOW_PARALLEL=1 if it runs a different workflow and job." >&2
    exit 1
  fi
fi

repo_dir="$(cd "$repo_dir" && pwd -P)"
mkdir -p "$reports_dir"
reports_dir="$(cd "$reports_dir" && pwd -P)"

# The cache volume keeps act's downloaded actions between runs, which is what
# lets later runs work offline with --action-offline-mode.
mounts=(
  -v /var/run/docker.sock:/var/run/docker.sock
  -v "${GH_REPORTER_CACHE_VOLUME:-gh-workflow-reporter-cache}:/root/.cache"
  -v "$repo_dir:/repo:ro"
  -v "$reports_dir:/reports"
)

# A worktree's .git file points at an absolute path in the main repository,
# so mount that git directory at the same path inside the container.
if common_dir="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  case "$common_dir" in
    "$repo_dir"/*) ;;
    *) mounts+=(-v "$common_dir:$common_dir:ro") ;;
  esac
fi

exec docker run --rm "${mounts[@]}" "$image" /repo "$workflow" "$event" ${offline_args[@]+"${offline_args[@]}"} "${@:3}"
