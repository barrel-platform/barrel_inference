# Model registry

`barrel_inference_server` carries an Ollama-compatible model registry on top
of the content-addressed blob cache from
[`fetching.md`](fetching.md). One manifest per `name:tag`,
GGUF-derived metadata sniffed at pull time, blob deduplication via
sha256.

## Layout

Under the cache root (default `~/Library/Caches/barrel_inference_server/models`
on macOS, `~/.cache/barrel_inference_server/models` on Linux, override with
`{model_cache_dir, "/path"}` in `sys.config`):

```
<root>/
  blobs/sha256-<hex>.gguf            content-addressed blob
  refs/<spec_hash>.ref               UTF-8 text file: absolute path to blob
  tmp/<spec_hash>.part               resumable download
  manifests/<name-encoded>/<tag>.json
  kv_cache/                          disk-tier KV cache
```

`<name-encoded>` replaces `/` with `:` so HuggingFace org/repo paths
fit cleanly under one directory level.

## Manifest fields

```json
{
  "name": "Qwen/Qwen2.5-7B-Instruct-GGUF",
  "tag": "main",
  "spec": "hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf",
  "digest": "sha256:a96b16179dc6cc9afdf0cf7a96a80c199cbd00b9be207c3465be21cb721cca5e",
  "blob_path": "/.../blobs/sha256-a96b...gguf",
  "size_bytes": 3808391072,
  "format": "gguf",
  "architecture": "qwen2",
  "family": "qwen",
  "parameter_size": "7.6B",
  "quantization": "q3_k_m",
  "context_size": 32768,
  "embedding_length": 3584,
  "chat_template": "...verbatim from GGUF...",
  "loader": {
    "n_gpu_layers": 0,
    "n_ctx": 4096,
    "n_batch": 512,
    "quant_type": "q3_k_m",
    "quant_bits": 3
  },
  "modified_at": "2026-05-11T07:34:52Z"
}
```

Modelfile-installed entries also get:

```json
{
  "system": "You are a pirate.",
  "template": "...override...",
  "parameters": {"num_ctx": 8192, "temperature": 0.7, "stop": ["<|im_end|>"]}
}
```

## Pull semantics

`barrel-inference pull <spec>` (or `POST /api/pull`) accepts:

- Short Ollama name: `llama3` -> `ollama://library/llama3:latest`
- Full Ollama spec: `ollama://library/llama3:8b`
- HuggingFace repo: `hf://Org/Repo` (auto-picks the best GGUF in
  the repo - `Q4_K_M > Q5_K_M > Q4_0 > Q8_0`, then first `*.gguf`
  alphabetically)
- HuggingFace file: `hf://Org/Repo/path.gguf[@revision]`
- Plain HTTPS: `https://...`
- Local file: `file:///abs/path.gguf` or `/abs/path.gguf`

`HF_TOKEN` is honoured for gated repos.

A concurrent `pull` for the same spec is deduped: the second caller
attaches to the first call's worker via `barrel_inference_server_fetch_srv`.

Streaming pulls emit NDJSON status events:

```
{"status":"pulling manifest"}
{"status":"pulling sha256:...","digest":"...","total":N,"completed":M}
{"status":"verifying sha256 digest"}
{"status":"writing manifest"}
{"status":"success"}
```

## Modelfile (`/api/create`)

v0.1 honours `FROM`, `PARAMETER`, `SYSTEM`, `TEMPLATE`. Other
directives (`ADAPTER`, `MESSAGE`, `LICENSE`) return 400
`modelfile_directive_not_supported`.

Example: derive a Pirate variant from a base model.

```sh
curl -X POST http://127.0.0.1:8080/api/create \
  -H 'content-type: application/json' \
  -d @- <<'JSON'
{
  "name": "pirate:v1",
  "modelfile": "FROM Qwen/Qwen2.5-7B-Instruct-GGUF:main\nPARAMETER num_ctx 8192\nPARAMETER temperature 0.7\nSYSTEM \"You are a pirate.\"\n"
}
JSON
```

`PARAMETER num_ctx` overrides the manifest's `context_size`
(itself capped at the server-wide `max_context_size`, default 4096).
`PARAMETER temperature` and friends are stored under
`manifest.parameters` and merged into the loader / sampler config.

## Aliasing + cleanup

```sh
# One blob, two names
barrel-inference copy "Qwen/Qwen2.5-7B-Instruct-GGUF:main" "qwen:7b"

# Delete a manifest. Blob is preserved (might back another alias).
barrel-inference rm "qwen:7b"
```

No GC of orphan blobs in v0.1; if a blob's last alias is deleted
the blob file remains on disk. A future `POST /api/gc` (or `barrel_inference
gc`) is on the backlog.

## Keep-alive eviction

Each request bumps a per-model active counter; the unload timer is
only armed when the counter returns to zero. A long generation
therefore never gets unloaded mid-stream.

```sh
# Default TTL after the last request (server-wide):
{barrel_inference_server, [{keep_alive_default_ms, 300000}]}      % 5 min

# Per-request overrides on /api/* endpoints:
curl ... -d '{"model":"qwen7b","prompt":"","keep_alive":0}'      % unload now
curl ... -d '{"model":"qwen7b","prompt":"","keep_alive":"1h"}'   % 1 hour TTL
curl ... -d '{"model":"qwen7b","prompt":"","keep_alive":-1}'     % never auto-unload
```

`/v1/*` endpoints silently accept `keep_alive` in the body
(no-op) for SDK compatibility.

## `barrel-inference ps`

Reports which models are currently in memory:

```
NAME                                SIZE     DIGEST        UNTIL
Qwen/Qwen2.5-7B-Instruct-GGUF:main  3.81 GB  a96b16179dc6  never
```

`UNTIL` is the ISO timestamp at which the keep-alive timer will
fire, or `never` when the model is held forever (`keep_alive: -1`)
or has at least one active request in flight.

## Auto-pull

Off by default. With `{auto_pull, true}` in `sys.config`, a request
for an unknown model triggers a synchronous pull through the same
machinery before loading. Useful in personal dev setups, risky in
shared / production deployments (large unexpected downloads).
