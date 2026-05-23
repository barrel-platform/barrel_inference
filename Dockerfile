# Multi-stage build for the barrel_inference umbrella:
#   1) builder: fetch deps, build the NIF (vendored llama.cpp via cmake),
#      assemble the prod release, build the barrel-inference CLI escript.
#   2) runtime: minimal Debian image with only the assembled release.
#
# glibc-based Debian: the cmake'd llama.cpp links libstdc++ from the same
# toolchain. For musl / Alpine you would rebuild the NIF against musl.

ARG OTP_VERSION=28
# erlang:28 is published on Debian 13 (trixie); there is no -bookworm
# variant for OTP 28. Keep builder + runtime on the same suite so the
# NIF's libstdc++ ABI matches.
ARG DEBIAN_VERSION=trixie

# ============================================================================
# Stage 1: build
# ============================================================================
FROM erlang:${OTP_VERSION} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
        build-essential \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Umbrella build inputs: the lock, every app (sources, per-app rebar.config,
# and the runtime c_src with vendored llama.cpp), and the release config.
COPY rebar.config rebar.lock ./
COPY config ./config
COPY apps ./apps

# Build the prod release (ERTS bundled) and the CLI escript, then drop the
# barrel-inference CLI next to the daemon start script so a single PATH entry
# exposes both the daemon and the client.
RUN rebar3 as prod release \
    && rebar3 as prod escriptize \
    && cp _build/prod/bin/barrel-inference \
          _build/prod/rel/barrel_inference_server/bin/barrel-inference

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
    && useradd --create-home --shell /bin/bash barrel_inference

WORKDIR /opt/barrel_inference_server

COPY --from=builder --chown=barrel_inference:barrel_inference \
     /src/_build/prod/rel/barrel_inference_server ./

USER barrel_inference

# Cache lives under the user's home so a bind mount survives rebuilds.
ENV XDG_CACHE_HOME=/home/barrel_inference/.cache

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["./bin/barrel_inference_server"]
CMD ["foreground"]
