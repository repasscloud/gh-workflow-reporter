FROM python:3.12-slim

ARG ACT_VERSION=0.2.89
# Set automatically by BuildKit to the build platform (amd64, arm64, ...).
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git curl ca-certificates docker.io && \
    rm -rf /var/lib/apt/lists/*

# act release assets use x86_64 rather than Docker's amd64 naming.
RUN case "${TARGETARCH:-amd64}" in \
      amd64) ACT_ARCH=x86_64 ;; \
      *) ACT_ARCH="${TARGETARCH}" ;; \
    esac && \
    curl -fsSL \
    "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_${ACT_ARCH}.tar.gz" \
    -o /tmp/act.tar.gz && \
    tar -xzf /tmp/act.tar.gz -C /usr/local/bin act && \
    rm /tmp/act.tar.gz

WORKDIR /app
COPY runner.py report.py ./

ENTRYPOINT ["python", "/app/runner.py"]
