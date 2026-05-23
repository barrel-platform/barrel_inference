# Multi-stage build:
#   1) builder: pull deps, build the erllama NIF + the release.
#   2) runtime: minimal Debian image with only the assembled release.
#
# Targets glibc-based Debian (cmake'd llama.cpp links against
# libstdc++ from the same toolchain that built it). For musl /
# Alpine you'd need to rebuild the NIF against musl - not done here.

ARG OTP_VERSION=28
ARG DEBIAN_VERSION=bookworm

# ============================================================================
# Stage 1: build
# ============================================================================
FROM erlang:${OTP_VERSION}-${DEBIAN_VERSION} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
        build-essential \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy rebar artefacts first so the dep fetch step caches separately
# from the source tree.
COPY rebar.config rebar.lock ./
RUN rebar3 deps

# Now the source.
COPY src ./src
COPY include ./include
COPY config ./config
COPY LICENSE ./

# Build the production release (with ERTS bundled).
RUN rebar3 as prod release

# ============================================================================
# Stage 2: runtime
# ============================================================================
FROM debian:${DEBIAN_VERSION}-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 \
        libgomp1 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash erllama

WORKDIR /opt/erllama_server

COPY --from=builder --chown=erllama:erllama \
     /src/_build/prod/rel/erllama_server ./

USER erllama

# Cache lives under the user's home so a bind mount survives container
# rebuilds. Override via {model_cache_dir, _} or by mounting at the
# default XDG path.
ENV XDG_CACHE_HOME=/home/erllama/.cache

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["./bin/erllama_server"]
CMD ["foreground"]
