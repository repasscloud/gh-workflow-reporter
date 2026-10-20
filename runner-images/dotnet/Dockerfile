# act runner image with the .NET SDK preinstalled, so workflows can build
# without downloading .NET on every run (and without network access).
ARG BASE_IMAGE=catthehacker/ubuntu:act-latest
FROM ${BASE_IMAGE}

# Match what actions/setup-dotnet would install for your global.json.
# Space-separated lists; each entry is passed to dotnet-install.sh --version.
ARG DOTNET_SDK_VERSIONS=10.0.402
ARG DOTNET_RUNTIME_VERSIONS=10.0.13

# setup-dotnet installs into /usr/share/dotnet on Linux.
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_NOLOGO=true \
    DOTNET_CLI_TELEMETRY_OPTOUT=true
ENV PATH=${DOTNET_ROOT}:${PATH}

RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    for v in ${DOTNET_SDK_VERSIONS}; do \
      bash /tmp/dotnet-install.sh --version "$v" --install-dir "$DOTNET_ROOT"; \
    done && \
    for v in ${DOTNET_RUNTIME_VERSIONS}; do \
      bash /tmp/dotnet-install.sh --runtime dotnet --version "$v" --install-dir "$DOTNET_ROOT"; \
    done && \
    rm /tmp/dotnet-install.sh && \
    dotnet --info
