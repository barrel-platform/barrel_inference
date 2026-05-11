# Changelog

All notable changes to erllama_server are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- HuggingFace + Ollama + HTTPS + file:// model fetcher
  (`erllama_server_fetch:fetch/1,2`, async variants, `search/1,2`)
  ported from `erllama`. Content-addressed blob cache with resume +
  sha256 verification; in-process dedupe of concurrent pulls.
- GGUF metadata reader (`erllama_server_gguf:read_metadata/1`),
  pure Erlang, no NIF.
- Models registry (`erllama_server_models`) with Ollama-style
  short names, manifests under `<cache_root>/manifests/<name>/<tag>.json`,
  GGUF metadata sniffing on pull, alias support via `copy/2`.
- Ollama-compatible `/api/tags`, `/api/pull`, `/api/show`,
  `/api/delete`, `/api/copy`, `/api/create`, `/api/search`.
- `erllama` CLI escript (`rebar3 escriptize` -> `_build/default/bin/erllama`).
  Subcommands: `pull`, `list`, `show`, `rm`, `copy`, `search`, `run`.
- Per-model load-progress streaming. The loader spawns a worker for
  the synchronous `erllama:load_model/2` call and emits
  `{erllama_load_progress, ModelId}` every 2 s while loading. The
  pipeline forwards each tick to the handler as
  `{pipeline, loading, _}`; chat / messages handlers emit SSE
  comments / Anthropic ping events so clients see activity during
  multi-second loads.
- `erllama_server_keepalive` gen_server tracks active requests per
  model and auto-unloads after `keep_alive_default_ms` (default
  5 min) of inactivity. Long generations never trigger an unload
  mid-stream because the timer is only armed when the active count
  reaches zero.
- Cowboy listener `idle_timeout` bumped to 30 min (configurable via
  `idle_timeout_ms` in `sys.config`) so long fetches and slow
  loads no longer close the connection at cowboy's default 60 s.
- Loader `manifest_to_config/1` caps `context_size` at
  `max_context_size` (default 4096) so models advertising 128 K
  contexts in their GGUF do not OOM at load time.
- Pipeline wraps every call into erllama in try/catch; a crashing
  model gen_statem returns a 500 JSON envelope or an SSE error
  frame instead of killing the cowboy request process.

## [0.1.0] - in progress

Initial release.

### Added

- OpenAI-compatible HTTP endpoints: `/v1/chat/completions`,
  `/v1/completions`, `/v1/embeddings`, `/v1/models[/:id]`. Streaming
  and non-streaming.
- Anthropic-compatible `/v1/messages` with named SSE events
  (`message_start`, `content_block_*`, `message_delta`,
  `message_stop`).
- Tool calls via grammar-constrained sampling. OpenAI and Anthropic
  tool arrays are converted to JSON Schema and then to GBNF, and
  passed to `erllama:infer/4` as the `grammar` Params field. v0.1
  buffers the JSON output and emits one final `tool_calls` /
  `tool_use` frame.
- Per-model semaphore queue (`erllama_server_queue`) with
  `pool_exhausted` returning 429 immediately or after a configurable
  wait. `concurrency`, `depth`, `timeout_ms` are policy-configurable
  per-model.
- Model aliases (`gpt-4o` -> `llama3-8b-q4`, etc.) configured in
  `sys.config`, hot-reloadable via
  `erllama_server_config:set_aliases/1`.
- Per-model loader (`erllama_server_loader`) that owns the blocking
  `erllama:load_model/2` call so the config server stays responsive.
  Concurrent waiters share one loader; per-waiter deadlines.
- `instrument`-backed metrics with Prometheus text format at
  `/metrics`. Counters, gauges, and histograms for requests,
  prefill/generation latency, tokens, queue depth.
- CORS middleware with preflight handling. Off by default.
- `X-Request-ID` propagation: echoed if present, minted as
  `req_<int>` if absent.
- Body-shape upfront caps: `max_messages`, `max_tools`,
  `max_request_body_bytes`, `max_embedding_inputs`. Bad inputs
  return 400 before the slow phase.
- Total / prefill / generation idle timeouts wired through the
  cowboy_loop handlers. Cancellation honours all three.
- Tool-buffer detection on streaming first byte (`{`) to avoid
  leaking grammar-mode JSON as assistant text.
- 61 CT tests across translate, grammar, and HTTP smoke.
- erlfmt + rebar3_lint + dialyzer integration with project-specific
  rule overrides.
