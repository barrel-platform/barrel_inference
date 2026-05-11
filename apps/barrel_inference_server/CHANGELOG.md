# Changelog

All notable changes to erllama_server are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-05-11

Initial public release. OpenAI-, Anthropic-, and Ollama-compatible
HTTP server on top of `erllama`.

### OpenAI surface

- `POST /v1/chat/completions` (streaming + non-streaming)
- `POST /v1/completions`
- `POST /v1/embeddings`
- `GET  /v1/models[/:id]` with alias passthrough
- Tool / function calling via grammar-constrained sampling. Tool
  arrays converted to JSON Schema then to GBNF and passed as the
  `grammar` field on `erllama:infer/4`. Tool-call output buffered
  and emitted as one final `tool_calls` frame.
- `response_format` (`text`, `json_object`, `{type: "json_schema",
  json_schema: {schema: ...}}`). All three compile to GBNF.

### Anthropic surface

- `POST /v1/messages` with named SSE events (`message_start`,
  `content_block_start`, `content_block_delta`, `content_block_stop`,
  `message_delta`, `message_stop`). No `[DONE]` sentinel.
- Tool calling buffered as one `content_block_*` frame.
- `thinking` parameter recognised; reasoning tokens flow as
  `thinking_delta` events.

### Ollama surface

- `POST /api/generate` (streaming NDJSON / non-streaming). Empty
  `prompt` triggers a preload returning
  `{done: true, done_reason: "load", load_duration: N}`.
- `POST /api/chat` (same semantics over messages).
- `POST /api/embed` + `POST /api/embeddings` (legacy single-prompt).
- `POST /api/pull` with HF, Ollama-registry, HTTPS, and `file://`
  sources. NDJSON progress: `pulling manifest` -> `pulling sha256:...`
  with rate-limited byte counts -> `verifying sha256 digest` ->
  `writing manifest` -> `success`.
- `GET  /api/tags`, `POST /api/show`, `POST /api/copy`,
  `DELETE /api/delete`, `POST /api/create` (with `FROM`, `PARAMETER`,
  `SYSTEM`, `TEMPLATE` directives), `POST /api/search`,
  `GET /api/ps`, `GET /api/version`.
- `keep_alive` parsing: integer seconds, duration strings
  (`"5m"`, `"30s"`, `"1h"`), `0` to unload immediately, `-1` /
  negative to keep loaded forever. `0` triggers a synchronous
  unload so the response is a real acknowledgement.
- `format: "json"` and `format: {schema}` for structured output.
  Both compile to GBNF via the same path the OpenAI
  `response_format` uses.

### Registry

- Models stored under `<cache_root>/manifests/<name>/<tag>.json`,
  blobs deduplicated under `<cache_root>/blobs/sha256-<hex>.gguf`.
- GGUF metadata reader (`erllama_server_gguf`, pure Erlang, no
  NIF). Extracts architecture, family, parameter size,
  quantisation, context length, embedding length, chat template
  at pull time. Stored verbatim in the manifest.
- Manifest Modelfile overrides: `system`, `template`,
  `parameters` (which `loader` merges into the
  `erllama:load_model/2` opts).

### Inference plumbing

- Per-model loader: `erllama_server_loader` spawns a monitored
  worker for `erllama:load_model/2` so the gen_server stays
  responsive while a load is in flight. Subscribers receive
  `{erllama_load_progress, ModelId}` every 2 s and
  `{erllama_load_done, ModelId, ok | {error, _}}` exactly once.
- Pipeline forwards load progress as `{pipeline, loading, _}`;
  chat handlers emit `: loading\n\n` SSE comments and Anthropic
  `event: ping` events so clients see activity during multi-second
  loads.
- Per-model keepalive (`erllama_server_keepalive`) with active
  request counter. Eviction timer only arms when active count
  reaches zero, so long generations never trigger a mid-stream
  unload.
- Per-model FIFO semaphore queue with `pool_exhausted` returning
  429. `concurrency`, `depth`, `timeout_ms` configurable per model.
- Cancel-on-disconnect: TCP close fires `terminate/3`, which calls
  `erllama:cancel/1`, releases the queue slot, kills the pipeline
  worker.
- Cowboy listener `idle_timeout` bumped to 30 min (configurable
  via `{idle_timeout_ms, _}`) so long fetches / loads do not get
  closed at cowboy's default 60 s.
- Loader `manifest_to_config/1` caps `context_size` at
  `max_context_size` (default 4096) so models advertising 128 K
  contexts in their GGUF do not OOM at load time.
- Pipeline wraps every call into `erllama` in try/catch; a
  crashing model gen_statem returns a 500 JSON envelope or an
  SSE / Anthropic error frame instead of killing the cowboy
  request process.

### Observability

- `instrument`-backed metrics with Prometheus text format at
  `/metrics`. Counters, gauges, and histograms for requests,
  prefill / generation latency, tokens, queue depth, active
  streams.
- `GET /health` (liveness) and `GET /health/ready` (readiness).
- `X-Request-ID` propagation: echoed if present, minted as
  `req_<int>` if absent.
- Per-request access log via a Cowboy `stream_handler`.

### CORS

- Off by default. When set to a map, full preflight handling +
  `Access-Control-Allow-*` headers on every response. Allow-list
  and `max_age` configurable.

### CLI

- `erllama` escript (`rebar3 escriptize` -> `_build/default/bin/erllama`).
  Subcommands: `pull`, `list` (ls), `ps`, `show`, `rm` (delete),
  `copy` (cp), `search`, `run`, `embed`, `unload`, `version`, `help`.
- Talks to the daemon over HTTP. Base URL via `ERLLAMA_HOST`
  (default `http://127.0.0.1:8080`).

### Body-shape caps

- `max_messages` (default 1024), `max_tools` (default 128),
  `max_request_body_bytes` (default 1 MiB), `max_embedding_inputs`
  (default 256). Bad inputs return 400 before the slow phase.

### Tooling

- erlfmt + rebar3_lint + dialyzer + xref integration with
  project-specific rule overrides.
- 127 eunit + 106 CT cases. CT real-model suite (`LLAMA_TEST_MODEL`
  gated) for end-to-end smoke against an actual GGUF.
- OpenAPI 3.1 spec at `openapi.yaml`.
- GitHub Actions CI (format, lint, xref, dialyzer, build matrix
  ubuntu + macos, eunit, ct).

### Out of scope for 0.1

- `POST /api/push` (publish to registry).
- Multi-modal inputs (images, audio).
- Modelfile `ADAPTER` (LoRA), `MESSAGE`, `LICENSE` directives.
- On-the-fly quantisation.
- Garbage collection of orphan blobs (deleting a manifest leaves
  the blob in place even if no other manifest references it).
