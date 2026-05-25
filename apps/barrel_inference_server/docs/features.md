# Roadmap & backlog

Tracked follow-ups for Barrel Inference Server. Shipped work lives in the git
history and the guides; this file is the not-yet-done list.

## Server-side tool executors

- **MCP bridge - DONE.** Barrel Inference Server connects (as an MCP client)
  to the servers in `mcp_servers` via `barrel_mcp`, and offers their
  tools on every request through the continue-loop
  (`barrel_inference_server_mcp` manager + catalog -> translate injection ->
  `barrel_inference_server_tool_executor_mcp`). See `guides/tools.md`.
  The catalog refreshes on `tools/list_changed` (timer is a fallback);
  stdio transport is verified against the Python reference server
  (gated CT); a server's resources are bridged as `<id>__list_resources`
  / `<id>__read_resource` meta-tools (capability-gated). Remaining:
  expose Barrel Inference's *own* tools as an MCP server (the other direction).
  MCP prompts are deliberately not bridged into the model loop (they
  are user-facing macros); a client-facing prompts surface is a
  possible later feature.
- **`code_interpreter`.** Highest value for coding agents, but heavy
  and security-sensitive: needs a real sandbox (container / firejail /
  separate service), not an in-process call. Do deliberately.
- **Retrieval / RAG.** Search a configured local corpus (vector store
  + embeddings) and fold hits into context. Medium effort.
- **Trivial:** `current_time`, `calculator`. Cheap, marginal value.

## Hardening (Barrel Inference Server)

- **Done in web_fetch:** SSRF guard (http(s) only; block
  loopback/private/link-local unless `allow_private`), TLS
  `verify_peer`, result-size cap.
- **Indirect prompt injection.** Search/fetch results are
  attacker-influenced web content folded into context. Can't fully
  prevent; results enter as tool/user content (never system).
  Document the risk in `guides/tools.md`.
- **API-key allowlist guidance.** Encourage `openai_api_keys` /
  `anthropic_api_keys` for any non-localhost bind; document in the
  deployment guide.

## Barrel Inference (engine) upstream

These need fixing in Barrel Inference (the NIF over llama.cpp), not here.
Ready-to-hand-off briefs live in `docs/`:

- `docs/barrel_inference_engine_hardening_prompt.md` - the engine-robustness
  items below (decode wedges, continue/3 grammar, byte-exact replay).
- `docs/barrel_inference_nif_hardening_prompt.md` - SIGSEGV / input-validation
  hardening (oversized prompts, malformed GGUF, chat-template badarg).

Hand either prompt to an barrel_inference-focused session pointed at the
sibling repo. Engine-robustness headlines:

- **Cold-admit wedge / unbounded non-interruptible decode (critical).**
  A wedged decode hangs the `gen_statem:call`; recovery is a full
  `unload`+reload. Bound each decode step at the NIF boundary, make
  the loop interruptible (so `cancel/1` lands), add a context
  watchdog that recovers in place.
- **`continue/3` must apply `Params.grammar`.** A continued round
  under `tool_choice = required` emitted free text - structured-output
  / forced-tool constraints break on continuation rounds.
- **Byte-exact continuation.** Expose generated token ids (or accept a
  caller transcript) so warm KV reuse works for tool-augmented
  multi-round turns without re-tokenization drift (also sidesteps the
  cold-infer-per-round cost in the loop).

## Protocol / loop follow-ups

- **KV-warm loop iterations.** The continue-loop pins the session
  (warm path), but `continue/3` carrying the grammar + byte-exact
  replay are engine prerequisites for fully reliable warm rounds; see
  the Barrel Inference items.
- **`store: false`** on `/v1/responses` - skip the response-store put
  when the client opts out.
- **`parallel_tool_calls: true`** - a multi-call GBNF root rule so the
  model can emit more than one tool call per turn (today one per
  round; `false` is honoured exactly).

## Client compatibility (ollama parity)

Found benchmarking barrel_memory (which drives the server like ollama).
Cases that work against ollama but fail here:

- **`/api/generate` 400s an oversized raw prompt instead of truncating.**
  The chat/messages path drops the oldest non-system message and retries
  (`pipeline.erl:258`); the raw-`prompt` path does not (`pipeline.erl:296`),
  so a prompt over `n_ctx` returns `400 "prompt is too long: N > M"`.
  ollama truncates raw prompts to `num_ctx`. Clients that send one big
  `prompt` (barrel_memory summarize/extract) get a hard error. Fix:
  truncate raw `/api/generate` prompts to fit `n_ctx` (head/tail), or make
  it configurable.
- **Per-request `num_ctx` is ignored; context is locked at load.**
  `options.num_ctx` is never read (`translate.erl`); `n_ctx` is fixed at
  load from the manifest / `max_context_size` (capped 32768). ollama lets
  a request size the window. Fix: honor `options.num_ctx` up to a server
  max, or surface the loaded context so clients can chunk.
- **No embedding-model path.** `/v1/embeddings` + `/api/embed` call
  llama.cpp embed on whatever model is loaded; a generative model returns
  `not_supported` -> 501 (`h_embeddings.erl:185`). Clients (barrel_memory)
  need an embedding model (nomic-embed-text class). Fix: support loading an
  embedding-capable GGUF (pooling) and route embeddings to it.
- **Minor: ollama-style model names 404.** barrel_memory's
  `context_models`/router use `qwen2.5:14b`, `codestral:22b`,
  `qwen2.5:0.5b`; unknown names 404 (no auto-pull by default). Alias them
  or enable `auto_pull` for drop-in parity.

## Clustering (barrel_inference_cluster)

`apps/barrel_inference_cluster` (v1, in development) is a facade that mirrors the
`barrel_inference` runtime API and routes each call across a mycelium overlay, so
a fleet behaves as one cluster-wide runtime. See `apps/barrel_inference/ROADMAP.md`
for the design.

**Build / run.** Clustering is **profile-only**: the stock release is unchanged.
A clustered facade node builds from the `cluster` profile:

```
rebar3 as cluster release -n barrel_inference_cluster
```

It uses `config/sys.config.cluster` (mycelium + `barrel_inference_cluster` env) and
`config/vm.args.cluster` (which selects the mycelium QUIC alt-dist:
`-proto_dist mycelium -epmd_module mycelium_epmd -start_epmd false`). Set a shared
non-default `dist_cookie` / `-setcookie` and `contact_nodes` seed set per cluster.
The default `config/sys.config` and `config/vm.args` are untouched. (Dependency
note: the umbrella pins `quic` to 1.4.x so hackney and mycelium share one NIF.)

**Phase 2 — wire the server onto the facade (not yet done).** Add an
`engine_module` indirection (default `barrel_inference`) and route only the
request-path / cluster-visible call sites through `barrel_inference_cluster`;
node-local lifecycle stays on the runtime:

- → facade: `pipeline` infer/continue/apply_chat_template/tokenize/reset_session,
  `h_messages`/`h_chat`/`h_responses` cancel/end_session, `h_ollama` cancel,
  `h_embeddings` tokenize/embed.
- → facade (aggregate): `h_models`/`h_api` list_models, `config` model_info readiness.
- → LOCAL (keep runtime): `loader` load_model, `keepalive`/`h_ollama`/`pipeline`
  unload, `h_health` list_models, `metrics` counters.

Reconcile `barrel_inference_server_queue` admission vs the facade's per-node
capacity at that point, and serve a `/cluster/*` admin endpoint for the CLI
(`barrel-inference cluster status|nodes`).
