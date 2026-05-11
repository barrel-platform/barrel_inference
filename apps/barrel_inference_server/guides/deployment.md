# Deployment

Three supported shapes today, in order of how hands-off you want
it to be:

1. **Release tarball** — the canonical artefact. Bundles ERTS, runs
   anywhere with a matching libc/libstdc++.
2. **Docker image (CPU)** — `ghcr.io/benoitc/erllama_server:latest`,
   multi-arch (linux/amd64, linux/arm64). No GPU.
3. **Docker image (CUDA)** — `ghcr.io/benoitc/erllama_server:cuda`,
   linux/amd64 only. Compiled with `-DGGML_CUDA=ON`; runs with
   `--gpus all`.

## Release tarball

```sh
rebar3 as prod tar
scp _build/prod/rel/erllama_server/erllama_server-0.1.0.tar.gz host:/opt/
ssh host
  cd /opt
  tar xzf erllama_server-0.1.0.tar.gz
  bin/erllama_server daemon
```

Stop with `bin/erllama_server stop`. Foreground / console modes are
`bin/erllama_server foreground` and `bin/erllama_server console`.

## Docker (CPU)

```sh
docker run -d --name erllama \
  -p 8080:8080 \
  -v erllama-cache:/home/erllama/.cache \
  -e ERLLAMA_BOOTSTRAP_MODELS="hf://Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  ghcr.io/benoitc/erllama_server:latest
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
  ghcr.io/benoitc/erllama_server:latest
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
  ghcr.io/benoitc/erllama_server:cuda
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

The repository ships a [`docker-compose.yml`](https://github.com/benoitc/erllama_server/blob/main/docker-compose.yml)
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
