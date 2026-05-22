# Roadmap & backlog

Tracked follow-ups for erllama_server. Shipped work lives in the git
history and the guides; this file is the not-yet-done list.

## Server-side tool executors

- **MCP bridge - DONE.** erllama_server connects (as an MCP client)
  to the servers in `mcp_servers` via `barrel_mcp`, and offers their
  tools on every request through the continue-loop
  (`erllama_server_mcp` manager + catalog -> translate injection ->
  `erllama_server_tool_executor_mcp`). See `guides/tools.md`.
  The catalog refreshes on `tools/list_changed` (timer is a fallback);
  stdio transport is verified against the Python reference server
  (gated CT). Remaining: bridge MCP resources; expose erllama's *own*
  tools as an MCP server (the other direction).
- **`code_interpreter`.** Highest value for coding agents, but heavy
  and security-sensitive: needs a real sandbox (container / firejail /
  separate service), not an in-process call. Do deliberately.
- **Retrieval / RAG.** Search a configured local corpus (vector store
  + embeddings) and fold hits into context. Medium effort.
- **Trivial:** `current_time`, `calculator`. Cheap, marginal value.

## Hardening (erllama_server)

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

## erllama (engine) upstream

These need fixing in erllama (the NIF over llama.cpp), not here.
Ready-to-hand-off briefs live in `docs/`:

- `docs/erllama_engine_hardening_prompt.md` - the engine-robustness
  items below (decode wedges, continue/3 grammar, byte-exact replay).
- `docs/erllama_nif_hardening_prompt.md` - SIGSEGV / input-validation
  hardening (oversized prompts, malformed GGUF, chat-template badarg).

Hand either prompt to an erllama-focused session pointed at the
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
  the erllama items.
- **`store: false`** on `/v1/responses` - skip the response-store put
  when the client opts out.
- **`parallel_tool_calls: true`** - a multi-call GBNF root rule so the
  model can emit more than one tool call per turn (today one per
  round; `false` is honoured exactly).
