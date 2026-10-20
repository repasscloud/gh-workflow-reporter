# gh-workflow-reporter

Run a GitHub Actions workflow on your own machine with [act](https://github.com/nektos/act), inside Docker, and get an HTML report of the run. It works on a local repository or git worktree, or on a GitHub repository by URL. Once its caches are filled, it can run offline.

Each run writes these files to the reports directory:

| File           | Contents                                              |
| -------------- | ----------------------------------------------------- |
| `report.html`  | Run status, duration, error count and a searchable log, grouped by job |
| `summary.json` | The same summary in machine-readable form             |
| `workflow.log` | Raw act output (JSON lines)                           |
| `artifacts/`   | Anything the workflow uploads with `actions/upload-artifact` |

The container exits with the workflow's exit code, so you can also use it in scripts.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Running with gh-report.sh](#running-with-gh-reportsh)
- [Running with docker run](#running-with-docker-run)
- [Passing extra flags to act](#passing-extra-flags-to-act)
- [Secrets, variables and environment](#secrets-variables-and-environment)
- [Workflows whose tests use Testcontainers](#workflows-whose-tests-use-testcontainers)
- [Running offline](#running-offline)
- [.NET runner image](#net-runner-image)
- [One run at a time](#one-run-at-a-time)
- [Runner images](#runner-images)
- [Troubleshooting](#troubleshooting)
- [Cleaning up](#cleaning-up)
- [Limitations](#limitations)
- [How it works](#how-it-works)

## Requirements

- Docker. Docker Desktop on macOS works.
- Access to the Docker socket. act starts each job as its own container on your Docker host.
- `bash` and `git` on the host, if you use `gh-report.sh`.

## Quick start

```sh
# 1. Build the image (once, and again after changing anything in this repo)
cd /path/to/gh-workflow-reporter
docker build -t gh-workflow-reporter .

# 2. Put the wrapper script on your PATH (optional, but makes life easier)
ln -s "$PWD/gh-report.sh" /usr/local/bin/gh-report

# 3. Run a workflow from inside any repository or worktree
cd ~/code/my-project
gh-report .github/workflows/ci.yml push
open reports/report.html
```

The image works on both `amd64` and `arm64` hosts. To use a different act release, run:

```sh
docker build --build-arg ACT_VERSION=0.2.89 -t gh-workflow-reporter .
```

## Running with gh-report.sh

```text
gh-report.sh [-C DIR] [-o REPORTS_DIR] [-O] WORKFLOW [EVENT [ACT_ARGS...]]
```

| Argument / option | Default | Meaning |
| ----------------- | ------- | ------- |
| `-C DIR` | current directory | Repository or worktree to run |
| `-o REPORTS_DIR` | `./reports` | Where the report files are written |
| `-O` | off | Offline: use cached actions and local images only. See [Running offline](#running-offline) |
| `WORKFLOW` | (required) | Path to the workflow **relative to the repository root**, e.g. `.github/workflows/ci.yml`. Must be under `.github/workflows/` and end in `.yml` or `.yaml` |
| `EVENT` | `push` | Event to simulate: `push`, `pull_request`, `workflow_dispatch`, or any other event act supports |
| `ACT_ARGS` | none | Passed straight to act. See [Passing extra flags to act](#passing-extra-flags-to-act). To use them, you must also give `EVENT` |

| Environment variable | Default | Meaning |
| -------------------- | ------- | ------- |
| `GH_REPORTER_IMAGE` | `gh-workflow-reporter` | Docker image to run |
| `GH_REPORTER_CACHE_VOLUME` | `gh-workflow-reporter-cache` | Docker volume that keeps act's downloaded actions between runs |
| `GH_REPORTER_ALLOW_PARALLEL` | unset | Set to `1` to start even if another run is active. See [One run at a time](#one-run-at-a-time) |

Options (`-C`, `-o`, `-O`) go **before** the workflow path. Anything after the event is passed to act.

What the script does for you:

- Mounts the repository read-only at `/repo`, so the workflow cannot change your files. Uncommitted changes are still included in the run.
- Handles git worktrees. A worktree's `.git` file points to an absolute path in the main repository, so the script also mounts that git directory at the same path inside the container.
- Keeps act's downloaded actions in a Docker volume, so later runs are faster and can work offline.
- Refuses to start while another run is active. See [One run at a time](#one-run-at-a-time).

### Examples

From inside a repository:

```sh
gh-report .github/workflows/ci.yml                       # push (default)
gh-report .github/workflows/ci.yml pull_request
gh-report .github/workflows/release.yml workflow_dispatch
```

From anywhere, pointing at a worktree and writing the reports outside it:

```sh
gh-report -C ~/worktrees/my-project-feature-x \
  -o ~/gh-reports/feature-x \
  .github/workflows/ci.yml workflow_dispatch
```

Without `-o`, a `reports/` folder is created in the directory you run from. If that is inside the repository, either add `reports/` to `.gitignore` or use `-o`.

## Running with docker run

`gh-report.sh` is a wrapper around `docker run`. You can call the image directly:

```text
SOURCE WORKFLOW [EVENT [ACT_ARGS...]]
```

`SOURCE` is either an `https://github.com/...` URL, or the absolute path of a directory mounted into the container (for example `/repo`).

A local repository:

```sh
mkdir -p reports
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v gh-workflow-reporter-cache:/root/.cache \
  -v "$PWD:/repo:ro" \
  -v "$PWD/reports:/reports" \
  gh-workflow-reporter /repo .github/workflows/ci.yml push
```

A git worktree also needs the main repository's git directory, mounted at its original path:

```sh
common="$(git rev-parse --path-format=absolute --git-common-dir)"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v gh-workflow-reporter-cache:/root/.cache \
  -v "$PWD:/repo:ro" \
  -v "$common:$common:ro" \
  -v "$PWD/reports:/reports" \
  gh-workflow-reporter /repo .github/workflows/ci.yml push
```

A GitHub repository by URL. It is shallow-cloned inside the container, so this needs network access:

```sh
mkdir -p reports
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/reports:/reports" \
  gh-workflow-reporter https://github.com/owner/repository .github/workflows/ci.yml push
```

The `gh-workflow-reporter-cache` volume is optional, but without it act downloads every action again on each run. Plain `docker run` doesn't have the [one-run-at-a-time check](#one-run-at-a-time).

## Passing extra flags to act

Any arguments after the event are passed to act unchanged. This works with both `gh-report.sh` and `docker run`.

| Flag | Use |
| ---- | --- |
| `--matrix KEY:VALUE` | Keep only the matrix combinations where `KEY` equals `VALUE`. It applies to every job whose matrix has that key, including `include:` lists, and can be repeated |
| `-j JOB_ID` | Run one job (the key under `jobs:`, not its display name), plus any jobs it `needs:` |
| `--input NAME=VALUE` | Inputs for a `workflow_dispatch` workflow |
| `--env NAME=VALUE` | Environment variable for every job |
| `-s NAME=VALUE`, `--var NAME=VALUE` | Secrets and `vars.*`. See [Secrets, variables and environment](#secrets-variables-and-environment) |
| `-P LABEL=IMAGE` | Use a different image for a `runs-on` label, e.g. the [.NET runner image](#net-runner-image). It overrides the defaults in [Runner images](#runner-images) |
| `--pull=false` | Don't try to pull job images. Required for images that exist only locally (`-O` sets this) |
| `--container-options "..."` | Extra `docker run` options for job containers, e.g. a volume |
| `--container-architecture linux/amd64` | Run jobs as amd64 on an Apple Silicon Mac. Slower, because it uses emulation |

Run only the Linux entries of a matrix that also lists Windows and macOS:

```sh
gh-report .github/workflows/ci.yml workflow_dispatch --matrix os:ubuntu-latest
```

Run `docker run --rm --entrypoint act gh-workflow-reporter --help` to see every act flag.

## Secrets, variables and environment

No secrets are passed in by default. Steps that read `secrets.*`, including `secrets.GITHUB_TOKEN`, see empty values unless you supply them.

Pass a secret or variable on the command line:

```sh
gh-report .github/workflows/deploy.yml workflow_dispatch -s API_KEY=abc123 --var ENVIRONMENT=staging
```

Values on the command line end up in your shell history. To avoid that, use files. act runs from the repository root, so file paths are relative to the repository, and act reads these files automatically if they exist:

| File (in the repository root) | Read as | Change with |
| ----------------------------- | ------- | ----------- |
| `.secrets` | Secrets, one `NAME=value` per line | `--secret-file PATH` |
| `.env` | Environment variables for every job | `--env-file PATH` |

If your repository has an `.env` file for other purposes, act will load it into the jobs too. Make sure `.secrets` is in `.gitignore`.

## Workflows whose tests use Testcontainers

Some test suites start their own database containers with [Testcontainers](https://testcontainers.com), for example PostgreSQL, SQL Server or Oracle. These fail under act without extra settings. The usual error looks like this:

```text
DotNet.Testcontainers.Containers.ResourceReaperException : Initialization has been cancelled.
```

Why it happens:

- The tests run inside act's job container.
- Testcontainers starts the database containers on your Docker host, alongside the job container rather than inside it.
- It then tries to reach them on `localhost`. Inside the job container, `localhost` is the job container itself, so it never connects.

Pass these two variables to the job:

```sh
gh-report .github/workflows/ci.yml workflow_dispatch \
  --env TESTCONTAINERS_RYUK_DISABLED=true \
  --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal
```

| Variable | Effect |
| -------- | ------ |
| `TESTCONTAINERS_RYUK_DISABLED=true` | Turns off Ryuk, the cleanup container Testcontainers starts first. Ryuk is the one that fails to connect, as shown in the error above. Without Ryuk, a test run that crashes or is killed can leave database containers running. Check with `docker ps`. |
| `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal` | Makes Testcontainers reach the containers it starts through the Docker host instead of `localhost`. |

`host.docker.internal` is provided by Docker Desktop on macOS and Windows. With Docker Engine on Linux, set the variable to an address of the Docker host that the job container can reach instead.

A full example for a .NET repository in a git worktree, running only the Linux matrix entries of one job:

```sh
gh-report -C ~/worktrees/my-project -o ~/gh-reports/my-project \
  .github/workflows/ci.yml workflow_dispatch \
  --matrix os:ubuntu-latest -j build-test \
  --env TESTCONTAINERS_RYUK_DISABLED=true \
  --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal
```

## Running offline

A run reaches the internet for five kinds of things. To run offline, each one has to be available locally first:

| What | Where it comes from online | How to have it offline |
| ---- | -------------------------- | ---------------------- |
| Job images (`catthehacker/ubuntu`, or your own) | Docker Hub | `docker pull` them while online. Use `-O` so act doesn't try to pull again |
| Actions (`actions/setup-dotnet`, etc.) | GitHub | Do one online run with `gh-report.sh`, which caches them in the `gh-workflow-reporter-cache` volume. Then use `-O` |
| Toolchains installed by `setup-*` actions | Vendor download sites | Bake them into a runner image and skip the setup step under act. See [.NET runner image](#net-runner-image) |
| Packages (NuGet, npm, pip, ...) | Package registries | Keep the package cache in a Docker volume. Fill it with one online run |
| Images started by tests (Testcontainers) | Docker Hub | Run the tests once online, or `docker pull` the images |

`actions/checkout` needs no network for a local repository: act copies your files in directly. A GitHub URL as `SOURCE` always needs the network for the clone.

`-O` adds act's `--action-offline-mode` (reuse cached actions instead of fetching them) and `--pull=false` (use local images only). It only works if the actions have been cached by an earlier online run with the same cache volume.

### Example: a .NET workflow, fully offline

This was tested with the network cut off, for both the reporter container and the job container.

One-time preparation, while online:

1. Build the [.NET runner image](#net-runner-image) with the versions your workflow needs.
2. Make the workflow skip `actions/setup-dotnet` under act (see below).
3. Do one online run to cache the actions and NuGet packages:

   ```sh
   gh-report .github/workflows/ci.yml push \
     -P ubuntu-latest=gh-workflow-reporter-dotnet --pull=false \
     --container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages"
   ```

Then, offline:

```sh
gh-report -O .github/workflows/ci.yml push \
  -P ubuntu-latest=gh-workflow-reporter-dotnet \
  --container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages" \
  --env NuGetAudit=false
```

- `--container-options "-v gh-workflow-reporter-nuget:/root/.nuget/packages"` keeps NuGet packages in a volume, so `dotnet restore` doesn't need nuget.org.
- `--env NuGetAudit=false` turns off NuGet's vulnerability check. Offline, that check gives warning `NU1900`, and a build that treats warnings as errors then fails. Only use it for offline runs.
- Add the Testcontainers variables too if your tests need them.

## .NET runner image

`actions/setup-dotnet` downloads the .NET SDK on every run, which takes about 25 seconds and needs the internet. `runner-images/dotnet/Dockerfile` builds a runner image with the SDK already installed.

### Building it

Pick the versions `setup-dotnet` would install for your `global.json`. To find them, run the workflow once online and search the report for `Installed version is`. For example, `global.json` `10.0.300` with `rollForward: latestFeature` gave SDK `10.0.402` and runtime `10.0.13`.

```sh
docker build -t gh-workflow-reporter-dotnet \
  --build-arg DOTNET_SDK_VERSIONS="10.0.402" \
  --build-arg DOTNET_RUNTIME_VERSIONS="10.0.13" \
  runner-images/dotnet
```

| Build argument | Default | Meaning |
| -------------- | ------- | ------- |
| `DOTNET_SDK_VERSIONS` | `10.0.402` | Space-separated SDK versions to install |
| `DOTNET_RUNTIME_VERSIONS` | `10.0.13` | Space-separated .NET runtime versions to install |
| `BASE_IMAGE` | `catthehacker/ubuntu:act-latest` | Image to build on top of |

Rebuild it when your `global.json` moves to a newer SDK.

### Using it

Point a `runs-on` label at it with `-P`. Because the image only exists locally, also pass `--pull=false`, or use `-O`:

```sh
gh-report .github/workflows/ci.yml push -P ubuntu-latest=gh-workflow-reporter-dotnet --pull=false
```

**Online**, nothing else is needed. `setup-dotnet` still runs, but finds the versions already installed and skips the download, so the step takes about 3 seconds instead of 25. If your `global.json` resolves to a newer version than the image has, `setup-dotnet` downloads it as usual.

**Offline**, `setup-dotnet` fails even with the SDK installed. Before it checks what is installed, it always asks the internet which version a channel like `10.0` currently means. Offline it retries for several minutes and then fails. act sets `ACT=true` inside jobs, so skip the step when running under act:

```yaml
      - uses: actions/setup-dotnet@v4
        if: ${{ !env.ACT }}
        with:
          global-json-file: global.json
```

On GitHub, `ACT` isn't set, so the step runs as before. Under act, the job uses the SDK from the image. The image's SDK must still satisfy your `global.json`, or `dotnet` refuses to run.

## One run at a time

act names each job container after the workflow and job, for example `act-CI-Build-and-test-ubuntu-latest-<hash>`. Nothing in that name is unique to a run, and act 0.2.89 has no option to change it. If a second run of the same job starts, act deletes the first run's container and creates its own. The first run's current step then dies with errors like these:

```text
exitcode '137': failure
Error response from daemon: RWLayer of container ... is unexpectedly nil
```

This can also happen when the two runs come from different worktrees of the same repository, because they share workflow and job names.

To prevent this, `gh-report.sh` refuses to start while any container from the `gh-workflow-reporter` image is running, and lists what it found:

```text
Another gh-workflow-reporter run is active:
  determined_boyd  (started 3 minutes ago)
Wait for it to finish, or set GH_REPORTER_ALLOW_PARALLEL=1 if it runs a different workflow and job.
```

If you know the other run uses a different workflow or job name, start anyway:

```sh
GH_REPORTER_ALLOW_PARALLEL=1 gh-report .github/workflows/lint.yml push
```

Plain `docker run` has no such check. Run `docker ps --filter ancestor=gh-workflow-reporter` first to make sure nothing else is running.

## Runner images

By default, jobs run in these `catthehacker` images:

| `runs-on`       | Image                              |
| --------------- | ---------------------------------- |
| `ubuntu-latest` | `catthehacker/ubuntu:act-latest`   |
| `ubuntu-24.04`  | `catthehacker/ubuntu:act-latest`   |
| `ubuntu-22.04`  | `catthehacker/ubuntu:act-22.04`    |

They are large, and the first run downloads them. To pull them ahead of time:

```sh
docker pull catthehacker/ubuntu:act-latest
docker pull catthehacker/ubuntu:act-22.04
```

Override any of them with `-P LABEL=IMAGE`. Labels not in this table (for example `ubuntu-20.04` or a self-hosted label) need a `-P` mapping, or act skips the job.

## Troubleshooting

| Symptom in the report | Cause | Fix |
| --------------------- | ----- | --- |
| `exitcode '137'` together with `RWLayer of container ... is unexpectedly nil` | Another run of the same job deleted this run's container | Run one at a time. See [One run at a time](#one-run-at-a-time) |
| `exitcode '137'` on its own | The job was killed, often for running out of memory. Docker Desktop has a memory limit | Raise the memory in Docker Desktop's settings, or run fewer jobs (`-j`, `--matrix`) |
| `ResourceReaperException : Initialization has been cancelled` | Testcontainers can't reach the containers it started | See [Testcontainers](#workflows-whose-tests-use-testcontainers) |
| `setup-dotnet` stuck on `Unable to download .../latest.version` | No network. `setup-dotnet` always looks up the version online | Skip it under act. See [.NET runner image](#net-runner-image) |
| `error NU1900: Warning As Error: Error occurred while getting package vulnerability data` | NuGet's vulnerability check can't reach nuget.org | `--env NuGetAudit=false` for offline runs |
| `pull access denied` or `repository does not exist` for a local image | act tried to pull an image that exists only on your machine | Add `--pull=false`, or use `-O` |
| A Windows or macOS job is skipped | act only runs Linux jobs | Expected. Filter them out with `--matrix` |
| Nothing runs on `push` or `pull_request` | Branch or path filters in the trigger don't match your branch | Use `workflow_dispatch` if the workflow allows it |
| Repository or worktree errors about `.git` | A worktree's git directory isn't mounted | Use `gh-report.sh`, or add the extra mount shown in [Running with docker run](#running-with-docker-run) |
| GUI or timing-sensitive tests fail only here | Jobs run in a container, often on a different CPU architecture than GitHub's runners, and without a display | Check whether the test waits a fixed amount of time instead of waiting for a condition |

The raw act output is in `workflow.log` in the reports directory, one JSON object per line. The `msg` field holds the step output.

## Cleaning up

act removes job containers when a run finishes. These are left behind on purpose:

| Item | Created by | Remove with |
| ---- | ---------- | ----------- |
| `gh-workflow-reporter-cache` volume | `gh-report.sh` (cached actions) | `docker volume rm gh-workflow-reporter-cache` |
| `gh-workflow-reporter-nuget` volume | The NuGet example above | `docker volume rm gh-workflow-reporter-nuget` |
| `catthehacker/ubuntu` images | First run | `docker rmi catthehacker/ubuntu:act-latest catthehacker/ubuntu:act-22.04` |
| Database containers | Testcontainers, if a test run crashed with Ryuk turned off | `docker ps`, then `docker rm -f NAME` |

Removing the cache volumes is safe. They are filled again on the next online run.

## Limitations

- Only Linux runners are supported. Jobs that use `macos-*` or `windows-*` are not run. Use `--matrix` to filter them out of matrix builds explicitly.
- Branch and path filters on `push` / `pull_request` triggers may stop a workflow from running on your current branch. If that happens, use `workflow_dispatch` when the workflow allows it.
- Only one run of a given workflow job can be active at a time. See [One run at a time](#one-run-at-a-time).
- `setup-*` actions download toolchains, so offline runs need those baked into a runner image and the setup step skipped under act. A .NET image is included.
- On an Apple Silicon Mac, jobs run as `arm64`, while GitHub's hosted runners are `amd64`. Steps that download or run `amd64`-only binaries may fail unless you use `--container-architecture linux/amd64`.
- act aims to be compatible with GitHub Actions but differs in places. See the [act documentation](https://nektosact.com) for details.

## How it works

- `Dockerfile`: a small Python image with git, the Docker CLI and act.
- `runner.py`:
  - checks the arguments
  - clones the repository if `SOURCE` is a URL, or uses the mounted directory as-is
  - runs `act` with JSON output, the default runner images and the artifact server
  - writes `summary.json`, then `report.html` (built by `report.py`)
  - exits with act's exit code
- `report.py`: groups the JSON log by job and renders the HTML report.
- `gh-report.sh`: sets up the Docker mounts, the cache volume and the concurrency check, then runs the image.
- `runner-images/dotnet/Dockerfile`: optional runner image with the .NET SDK preinstalled.

act starts job containers on your Docker host through the mounted Docker socket. Your files are copied into each job container, so the read-only mount is never written to.
