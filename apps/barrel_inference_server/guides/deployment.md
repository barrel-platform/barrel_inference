# Deployment

Three supported shapes today, in order of how hands-off you want
it to be:

1. **Release tarball** — the canonical artefact. Bundles ERTS, runs
   anywhere with a matching libc/libstdc++.
2. **Docker image (CPU)** — `ghcr.io/barrel-platform/barrel_inference_server:latest`,
   multi-arch (linux/amd64, linux/arm64). No GPU.
3. **Docker image (CUDA)** — `ghcr.io/barrel-platform/barrel_inference_server:cuda`,
   linux/amd64 only. Compiled with `-DGGML_CUDA=ON`; runs with
   `--gpus all`.

## One-liner install (Linux + macOS)

```sh
curl -fsSL https://github.com/barrel-platform/barrel_inference/releases/latest/download/install.sh | sh
```

Detects OS + arch, downloads the right release tarball, untars to
`/usr/local/barrel_inference_server`, symlinks `barrel_inference_server` and `barrel_inference`
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
`https://github.com/barrel-platform/barrel_inference/releases`:

```
barrel_inference_server-0.1.0-darwin-arm64.tgz       Mac Apple Silicon, Metal
barrel_inference_server-0.1.0-darwin-x86_64.tgz      Mac Intel
barrel_inference_server-0.1.0-linux-amd64.tar.zst    Linux x86_64, CPU
barrel_inference_server-0.1.0-linux-amd64-cuda12.tar.zst   + NVIDIA CUDA 12
barrel_inference_server-0.1.0-linux-amd64-rocm.tar.zst     + AMD ROCm
barrel_inference_server-0.1.0-linux-arm64.tar.zst    Linux aarch64, CPU
```

Each tarball bundles the release **and the `barrel_inference` CLI escript**
under `bin/`, so one extract gives you both the daemon and the
client.

```sh
# Linux .tar.zst
curl -fLO https://github.com/barrel-platform/barrel_inference/releases/download/v0.1.0/barrel_inference_server-0.1.0-linux-amd64.tar.zst
sudo tar -C /opt --use-compress-program=zstd -xf barrel_inference_server-0.1.0-linux-amd64.tar.zst
/opt/barrel_inference_server/bin/barrel_inference_server daemon
/opt/barrel_inference_server/bin/barrel-inference version

# macOS .tgz
curl -fLO https://github.com/barrel-platform/barrel_inference/releases/download/v0.1.0/barrel_inference_server-0.1.0-darwin-arm64.tgz
sudo tar -C /opt -xzf barrel_inference_server-0.1.0-darwin-arm64.tgz
/opt/barrel_inference_server/bin/barrel_inference_server daemon
```

Stop with `bin/barrel_inference_server stop`. Foreground / console modes are
`bin/barrel_inference_server foreground` and `bin/barrel_inference_server console`.

## Building from source

```sh
rebar3 as prod release            # release in _build/prod/rel/barrel_inference_server/
rebar3 as prod escriptize         # CLI in _build/prod/bin/barrel_inference
rebar3 as prod tar                # tarball in _build/prod/rel/barrel_inference_server/
```

For a GPU build, pass through to the Barrel Inference CMake config:

```sh
BARREL_INFERENCE_OPTS="-DGGML_CUDA=ON" rebar3 as prod release   # NVIDIA
BARREL_INFERENCE_OPTS="-DGGML_HIP=ON"  rebar3 as prod release   # AMD
# macOS: Metal is auto-detected; no flag needed.
```

## Docker (CPU)

```sh
docker run -d --name barrel_inference \
  -p 8080:8080 \
  -v barrel_inference-cache:/home/barrel_inference/.cache \
  -e BARREL_INFERENCE_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  ghcr.io/barrel-platform/barrel_inference_server:latest
```

The container is **AI-ready** on first start: it pulls the
bootstrap model in the background while the listener accepts
requests. `curl http://localhost:8080/api/tags` reports the model
once the pull finishes (a few seconds for the ~400 MB Qwen 0.5B
example).

Override `BARREL_INFERENCE_BOOTSTRAP_MODELS` to whatever you want (comma-
separated list of fetch specs):

```sh
docker run -d --name barrel_inference \
  -e BARREL_INFERENCE_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-7B-Instruct-GGUF,llama3:8b" \
  ghcr.io/barrel-platform/barrel_inference_server:latest
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
docker run -d --name barrel_inference \
  --gpus all \
  -p 8080:8080 \
  -v barrel_inference-cache:/home/barrel_inference/.cache \
  -e BARREL_INFERENCE_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m.gguf" \
  ghcr.io/barrel-platform/barrel_inference_server:cuda
```

The image bakes llama.cpp with CUDA + cuBLAS. To actually offload
layers to the GPU, set `n_gpu_layers` in `model_default_opts` (or
in the manifest's `loader` sub-map via a Modelfile `PARAMETER`):

```sh
docker run --gpus all \
  -e ERL_FLAGS='-barrel_inference_server model_default_opts "#{n_gpu_layers=>99}"' \
  ...
```

Verify the GPU is visible from inside the container:

```sh
docker exec -it barrel_inference nvidia-smi
```

[nvidia-toolkit]: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

## Docker Compose

The repository ships a [`docker-compose.yml`](https://github.com/barrel-platform/barrel_inference/blob/main/docker-compose.yml)
with both profiles:

```sh
# CPU
docker compose up -d
# GPU
docker compose --profile gpu up -d
```

Both share the same `barrel_inference_cache` named volume so flipping
between profiles reuses already-pulled blobs.

## Hardening the daemon

`config/sys.config` knobs worth setting per environment:

```erlang
{barrel_inference_server, [
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

### NIF crash containment

llama.cpp is in-VM via the `barrel_inference` NIF. The chosen hardening
path is input validation at the NIF boundary, not subprocess
isolation. Barrel Inference 0.1.1+ refuses oversized prompts, classifies
malformed GGUFs, and rejects non-binary content with clean
`{error, _}` tuples. Future NIF-safety work follows the prompt at
[`docs/barrel_inference_nif_hardening_prompt.md`](https://github.com/barrel-platform/barrel_inference/blob/main/docs/barrel_inference_nif_hardening_prompt.md).
Subprocess isolation is deliberately out of scope: it would cost
the zero-copy token streaming, OTP cancel-on-disconnect cascade,
and in-process KV cache that make Barrel Inference valuable.

## Observability

Scrape `/metrics`:

```yaml
scrape_configs:
  - job_name: barrel_inference_server
    static_configs:
      - targets: ['barrel_inference:8080']
```

The metric set covers requests, prefill/generation latency,
tokens, queue depth, active streams. See
[`api.md`](api.md#observability).
