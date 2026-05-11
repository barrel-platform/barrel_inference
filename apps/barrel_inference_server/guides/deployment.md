# Deployment

Three supported shapes today, in order of how hands-off you want
it to be:

1. **Release tarball** — the canonical artefact. Bundles ERTS, runs
   anywhere with a matching libc/libstdc++.
2. **Docker image (CPU)** — `ghcr.io/erllama/erllama_server:latest`,
   multi-arch (linux/amd64, linux/arm64). No GPU.
3. **Docker image (CUDA)** — `ghcr.io/erllama/erllama_server:cuda`,
   linux/amd64 only. Compiled with `-DGGML_CUDA=ON`; runs with
   `--gpus all`.

## One-liner install (Linux + macOS)

```sh
curl -fsSL https://github.com/erllama/erllama_server/releases/latest/download/install.sh | sh
```

Detects OS + arch, downloads the right release tarball, untars to
`/usr/local/erllama_server`, symlinks `erllama_server` and `erllama`
into `/usr/local/bin`. Override defaults via flags:

```sh
curl -fsSL .../install.sh | sh -s -- --variant cuda12        # NVIDIA build
curl -fsSL .../install.sh | sh -s -- --prefix $HOME/.local   # user install
curl -fsSL .../install.sh | sh -s -- --version 0.1.0
```

Variants:

| Platform | Variant tag | Build flag |
|---|---|---|
| `linux-amd64` | (none) | CPU |
| `linux-amd64-cuda12` | `cuda12` | `-DGGML_CUDA=ON` (NVIDIA) |
| `linux-amd64-rocm` | `rocm` | `-DGGML_HIP=ON` (AMD) |
| `linux-arm64` | (none) | CPU |
| `darwin-arm64` | (none) | Metal (auto) |
| `darwin-x86_64` | (none) | CPU (Intel Macs) |

## Manual release tarball

Each release publishes per-platform tarballs at
`https://github.com/erllama/erllama_server/releases`:

```
erllama_server-0.1.0-darwin-arm64.tgz       Mac Apple Silicon, Metal
erllama_server-0.1.0-darwin-x86_64.tgz      Mac Intel
erllama_server-0.1.0-linux-amd64.tar.zst    Linux x86_64, CPU
erllama_server-0.1.0-linux-amd64-cuda12.tar.zst   + NVIDIA CUDA 12
erllama_server-0.1.0-linux-amd64-rocm.tar.zst     + AMD ROCm
erllama_server-0.1.0-linux-arm64.tar.zst    Linux aarch64, CPU
```

Each tarball bundles the release **and the `erllama` CLI escript**
under `bin/`, so one extract gives you both the daemon and the
client.

```sh
# Linux .tar.zst
curl -fLO https://github.com/erllama/erllama_server/releases/download/v0.1.0/erllama_server-0.1.0-linux-amd64.tar.zst
sudo tar -C /opt --use-compress-program=zstd -xf erllama_server-0.1.0-linux-amd64.tar.zst
/opt/erllama_server/bin/erllama_server daemon
/opt/erllama_server/bin/erllama version

# macOS .tgz
curl -fLO https://github.com/erllama/erllama_server/releases/download/v0.1.0/erllama_server-0.1.0-darwin-arm64.tgz
sudo tar -C /opt -xzf erllama_server-0.1.0-darwin-arm64.tgz
/opt/erllama_server/bin/erllama_server daemon
```

Stop with `bin/erllama_server stop`. Foreground / console modes are
`bin/erllama_server foreground` and `bin/erllama_server console`.

## Building from source

```sh
rebar3 as prod release            # release in _build/prod/rel/erllama_server/
rebar3 as prod escriptize         # CLI in _build/prod/bin/erllama
rebar3 as prod tar                # tarball in _build/prod/rel/erllama_server/
```

For a GPU build, pass through to the erllama CMake config:

```sh
ERLLAMA_OPTS="-DGGML_CUDA=ON" rebar3 as prod release   # NVIDIA
ERLLAMA_OPTS="-DGGML_HIP=ON"  rebar3 as prod release   # AMD
# macOS: Metal is auto-detected; no flag needed.
```

## Docker (CPU)

```sh
docker run -d --name erllama \
  -p 8080:8080 \
  -v erllama-cache:/home/erllama/.cache \
  -e ERLLAMA_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  ghcr.io/erllama/erllama_server:latest
```

The container is **AI-ready** on first start: it pulls the
bootstrap model in the background while the listener accepts
requests. `curl http://localhost:8080/api/tags` reports the model
once the pull finishes (a few seconds for the ~400 MB Qwen 0.5B
example).

Override `ERLLAMA_BOOTSTRAP_MODELS` to whatever you want (comma-
separated list of fetch specs):

```sh
docker run -d --name erllama \
  -e ERLLAMA_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-7B-Instruct-GGUF,llama3:8b" \
  ghcr.io/erllama/erllama_server:latest
```

## Docker (CUDA / NVIDIA GPU)

Requires the NVIDIA Container Toolkit on the host
([install guide][nvidia-toolkit]):

```sh
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Then:

```sh
docker run -d --name erllama \
  --gpus all \
  -p 8080:8080 \
  -v erllama-cache:/home/erllama/.cache \
  -e ERLLAMA_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m.gguf" \
  ghcr.io/erllama/erllama_server:cuda
```

The image bakes llama.cpp with CUDA + cuBLAS. To actually offload
layers to the GPU, set `n_gpu_layers` in `model_default_opts` (or
in the manifest's `loader` sub-map via a Modelfile `PARAMETER`):

```sh
docker run --gpus all \
  -e ERL_FLAGS='-erllama_server model_default_opts "#{n_gpu_layers=>99}"' \
  ...
```

Verify the GPU is visible from inside the container:

```sh
docker exec -it erllama nvidia-smi
```

[nvidia-toolkit]: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

## Docker Compose

The repository ships a [`docker-compose.yml`](https://github.com/erllama/erllama_server/blob/main/docker-compose.yml)
with both profiles:

```sh
# CPU
docker compose up -d
# GPU
docker compose --profile gpu up -d
```

Both share the same `erllama_cache` named volume so flipping
between profiles reuses already-pulled blobs.

## Hardening the daemon

`config/sys.config` knobs worth setting per environment:

```erlang
{erllama_server, [
  {port,                 8080},
  {ip,                   {0,0,0,0}},
  {num_acceptors,        100},
  %% Per-model FIFO queue. concurrency=1 means at most one inference
  %% per model at a time; depth caps the waitlist.
  {pool_exhausted_policy,
     {queue, #{concurrency => 1, depth => 100, timeout_ms => 30000}}},
  %% Per-request body cap.
  {max_request_body_bytes, 1048576},
  %% TTL after the last request before the model is evicted from RAM.
  %% Per-request `keep_alive` overrides this on /api/* endpoints.
  {keep_alive_default_ms, 300000},
  %% CORS: empty/off in dev; tighten in prod.
  {cors, off}
]}.
```

For production behind a reverse proxy, set `{ip, {127,0,0,1}}` and
terminate TLS at the proxy.

## Observability

Scrape `/metrics`:

```yaml
scrape_configs:
  - job_name: erllama_server
    static_configs:
      - targets: ['erllama:8080']
```

The metric set covers requests, prefill/generation latency,
tokens, queue depth, active streams. See
[`api.md`](api.md#observability).
