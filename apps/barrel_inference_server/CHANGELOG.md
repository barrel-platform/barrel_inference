# Changelog

All notable changes to Barrel Inference Server are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- Fourth `loader.weight_residency` mode: `lazy_then_pin_resident`. Loads
  with `MADV_RANDOM` (kernel does not read ahead); once the first request
  completes the scheduler calls the backend's `pin_resident_pages/1` to
  mlock just the working set the prompt selected. Pages outside the
  set still page in lazily on later prompts but are not pinned. The
  closest barrel-level approximation of Apple's "per-prompt expert
  routing" idea (AFM3) for off-the-shelf dense GGUFs. Operator-facing
  surface is identical to the other modes (manifest field + Modelfile
  PARAMETER + app env). One-shot per model load; failures are logged
  and the model continues unpinned.

- New `loader.weight_residency` manifest field (and matching Modelfile
  `PARAMETER weight_residency`). Accepts `eager` (current default,
  kernel reads ahead), `lazy` (`MADV_RANDOM`, the kernel only pages
  in weights on first touch — lower peak RSS, slightly higher first-
  token latency, useful for sparse-prompt agent workloads), and
  `pinned` (mlock the whole file — predictable jitter on fleet nodes
  with plenty of RAM). The loader maps the named mode to a
  `(use_mmap, use_mlock, prefetch)` triple on `model_opts`. Modelfile
  parameter wins over the manifest, which wins over the new fleet-wide
  `weight_residency_default` app env. Cross-platform mlock caveats
  (RLIMIT_MEMLOCK on macOS, capability/sysctl on Linux) are operator
  concerns — failures degrade to a logger warning, not a crash.

### Removed

- Per-family Erlang tool-call format modules (`qwen-xml`, `qwen3-coder`,
  `dsml`, `llama-python-tag`, `llama-pythonic`, `mistral-tool-calls`,
  `mistral-args`, `phi4-functools`, `glm45`, `bare-json`),
  `barrel_inference_server_tool_format` behaviour + registry,
  `src/tool_formats/' source directory,
  `barrel_inference_server_tool_scan' streaming module, and
  `barrel_inference_server_tool_replay' DETS store. Tool-call parsing
  routes through llama.cpp's `common_chat_parse' on the buffered
  response at `barrel_inference_done' via the
  `barrel_inference_server_autoparser' bridge.
- `barrel_inference_server_grammar:from_tools/2' tool-grammar generator.
  Tools requests now decode freely (empty grammar); the autoparser
  extracts calls at done. `from_response_format/1' stays for
  response_format / format directives.
- `loader.tool_call_format' / `loader.tool_call_markers' manifest
  fields (silently ignored if present in existing manifests; no
  re-pull needed).
- `tool_call_formats' app env (silently ignored if set).

### Changed

- Tool-call parsing moves from engine-side per-token marker capture
  to llama.cpp's `common_chat_parse' on the buffered response at
  `barrel_inference_done'. HTTP wire format unchanged.
- Pipeline renders all chat / messages requests through
  `barrel_inference:chat_apply/2' (autoparser), with the legacy
  `apply_chat_template/2' kept only as a fallback for backends that
  don't support chat at all. The `ParamsRef' is carried admit ->
  done via `{pipeline, templated, Tokens, ParamsRef}` (4-tuple,
  was 3-tuple).

### Changed

- Tool-call format families now live under
  `apps/barrel_inference_server/src/tool_formats/` and the registered
  set is the single ordered list in
  `apps/barrel_inference_server/include/barrel_inference_server_tool_formats.hrl`
  (macro `?BARREL_TOOL_FORMAT_FAMILIES`). Adding a new family is now
  exactly two files: one new module in the subfolder, one new line in
  the include list. The behaviour gains four new callbacks:
  `family_name/0`, `detect/1` (chat-template predicate + marker pair),
  and optional `payload_markers/0` (currently only `mistral-args`
  ships extras); `parse_all/1` and `post_parse_mode/0` are also
  declared as optional callbacks (the marker-less post-parse path).
  Both the registry map (`barrel_inference_server_tool_format:formats/0`)
  and the detection dispatch (`barrel_inference_server_tool_format:detect/1`)
  derive from the include macro; the `default_tool_call_formats/0`
  hand-rolled map and the inline `Candidates` / `SpecialCases` +
  `is_*_template/1` predicates in
  `barrel_inference_server_models:detect_tool_call_format/1` (plus
  `maybe_add_payload_markers/2`) are gone. No observable runtime
  behaviour change; no manifest / config / CI shape change. The
  `tool_call_formats` app env merge for operator-supplied custom
  families is preserved.

### Added

- New `glm45` tool-call format family. Covers zai-org / THUDM GLM-4.5,
  GLM-4.5-Air, and GLM-4.6 (wire-identical across the three; same
  tokenizer IDs 151352..151359 for the eight tool / arg markers, same
  chat-template emission block). The wire shape is the XML body
  `<tool_call>NAME\n<arg_key>K</arg_key>\n<arg_value>V</arg_value>...
  </tool_call>` where the function name lives on the first line and
  each argument is a `<arg_key>` / `<arg_value>` pair. All eight markers
  are SINGLE tokens in the tokenizer, so the family uses the engine's
  native marker capture path (qwen3-coder lineage) without any handler
  change: the engine emits `barrel_inference_tool_call_end` with the
  captured body and `parse/1` extracts the name and arg map. Values are
  JSON-decoded when they round-trip (numbers, booleans, arrays, objects,
  quoted strings) and kept as raw binaries for bare unquoted strings,
  mirroring qwen3-coder's `coerce/1`, since the GLM template renders
  non-string values via `tojson(ensure_ascii=False)` but bare strings
  unquoted. `canonicalise/1` round-trips message history bit-exact.
  Auto-detection at pull time keys on `<tool_call>` AND `<arg_key>`;
  qwen3-coder shares `<tool_call>` but uses `<function=`, so the two
  predicates are mutually exclusive on real templates. GLM-4.7 ships
  a different first-line layout and is intentionally NOT covered;
  future `glm47` family.
- New `phi4-functools` tool-call format family. Covers Microsoft
  Phi-4-mini-instruct and Phi-4-multimodal-instruct, which emit calls as
  `functools[{"name":...,"arguments":...}, ...]` — literal ASCII markers
  (not control tokens), JSON array body. The end marker `]` is a single
  common token, so the engine's `map_marker/2` would prematurely close
  the span on any nested `]` in an argument value; the family therefore
  uses the marker-less post-parse path (PR #22's mechanism) with a
  string-aware bracket-depth walker that finds the OUTER `]` matching
  the leading `[`, ignoring `]` inside JSON strings and inside nested
  arrays. The parser tolerates surrounding prose, accepts both
  `arguments` and `parameters` keys (some fine-tunes use the latter),
  and defaults missing arguments to `#{}`. The handlers'
  `maybe_post_parse_pythonic/1` is generalised to `maybe_post_parse/1`
  with a catch-all `_Mode` clause so it dispatches on ANY non-`none`
  post-parse mode (`pythonic`, `functools`, ...); the shipped
  `llama-pythonic` family is behaviour-unchanged. Auto-detection at
  pull time keys on the presence of `functools[` AND the `<|tool|>`
  declaration-block marker — both are required to avoid false-positiving
  on prose templates that mention the `functools` Python library.
  (The larger Phi-4 14B model does NOT support tool calling per
  Microsoft; this family covers `Phi-4-mini-instruct` and
  `Phi-4-multimodal-instruct` only.)
- New `llama-pythonic` tool-call format family. Covers the Llama 3.2 Instruct
  (1B, 3B) and Llama 3.3 70B Instruct zero-shot wire shape, which is a Python
  call-list `[func1(arg1='val1', arg2=True), func2(...)]` terminated by
  `<|eot_id|>` - NOT the Llama 3.1 `<|python_tag|>{json}<|eom_id|>` envelope.
  The existing `llama-python-tag` family stays valid for Llama 3.1 and for
  3.3's built-in-tools sub-mode; the new family is the zero-shot path for
  3.2 and 3.3. The parser is tolerant of single AND double quoted strings,
  Python literals (`True` / `False` / `None`) AND JSON equivalents
  (`true` / `false` / `null`), nested lists and dicts (string OR identifier
  keys), integers and floats including negatives and scientific notation,
  and an optional trailing `<|eot_id|>` literal. `canonicalise/1` round-trips
  through Python literals so a captured + replayed call is byte-stable.
  The family is **marker-less**: there is no single-token start marker
  suitable for the engine's `map_marker/2` (a bare `[` would false-positive
  on prose and code blocks), so it opts into a new **post-parse capture
  path** in the chat / messages handlers via a `post_parse_mode() ->
  pythonic` callback. At `barrel_inference_done` the handler runs the
  family's `parse_all/1` on the accumulated `buf_text` and injects the
  parsed calls as captured_calls; `buf_text` is reset so the response does
  NOT also emit the raw bracket list as content. Auto-detection at pull
  time picks `llama-pythonic` for chat templates that mention pythonic
  format AND carry `<|eot_id|>` but NOT `<|python_tag|>` (the 3.1
  signature). Two CT cases pin both directions. Streaming per-call SSE
  deltas are NOT in scope for this family - pythonic does not allow
  reliable partial-call boundaries; the handler emits one `tool_calls`
  block at done, with intermediate text deltas streaming normally while
  the model is generating.

### Fixed

- `mistral-tool-calls`, `llama-python-tag`, and `dsml` parse the marker-stripped
  shape that real backends produce. The NIF detokenizer runs with
  `llama_token_to_piece(..., /*special*/ false)`, which drops control-token markers
  from the captured `FullBin`; the three families above all split on a marker that
  is itself a control token (`[TOOL_CALLS]`, `<|python_tag|>`, `<｜tool▁sep｜>`) and
  so were silently broken on a real backend, returning `{error, no_markers}` for
  `mistral-tool-calls` and `llama-python-tag`, and parsing `functionNAME` as the
  function name for `dsml`. Each family's `parse/1` now accepts both the canonical
  marker-present shape AND the marker-stripped shape, mirroring the tolerance
  pattern shipped with the `mistral-args` family. Three small shared helpers
  (`strip_prefix/2`, `strip_suffix/2`, `split_at_first_brace/1`) are lifted into
  `barrel_inference_server_tool_format` so families don't reinvent them.
  Behavioural note for `dsml`: in the marker-stripped path the literal `function'
  type-prefix text is always stripped (the canonical wire reserves it), so a
  user-defined function whose name literally starts with `function' (e.g.
  `functionGetData`) loses that prefix on the marker-stripped path; this is
  documented and pinned by an eunit test.

### Added

- New `mistral-args` tool-call format family. Covers the Mistral tekken-tokenizer wire
  shape (`[TOOL_CALLS]<name>[ARGS]<json-args>`, repeated per call, terminated by `</s>`)
  used by Devstral-Small-2 (2507, 2512), Mistral-Small-3.1 / 3.2, Magistral, Ministral,
  and recent Codestral. The shipped `mistral-tool-calls` family parses the older
  JSON-array shape (`[TOOL_CALLS][{...}]`) and produced garbled `unknown {}` calls for
  these models. Auto-detection at pull time disambiguates the two shapes by requiring
  `[ARGS]` to appear AFTER `[TOOL_CALLS]` in the `chat_template` (mirroring the
  `is_qwen3_coder_template/1` disambiguation pattern); a classic Mistral template, or a
  template that documents `[ARGS]` only in an instructions block before `[TOOL_CALLS]`,
  still detects as `mistral-tool-calls`. The parser is tolerant of both the canonical
  wire shape and the real-backend captured shape (control-token markers are dropped by
  the engine's `special=false` detokenization, so `parse/1` sees `name{json}` with no
  marker bytes) and rejects truncated captures (empty args region) so a fake `({})`
  tool use can never reach the caller. Detection also auto-sets `payload_start=[ARGS]`
  for `mistral-args` so the args region uses the request's normal sampler instead of
  the greedy syntax sampler (without it the model tends to lock onto `[TOOL_CALLS]`
  after the args close and spam empty calls). Parallel tool calls round-trip via the
  engine's span-split on repeated start markers.

### Changed

- `parse_full_bin/2` in both `barrel_inference_server_h_chat` and
  `barrel_inference_server_h_messages` now drops a tool call when the family parser
  returns `{error, empty_args}` (a clearly-truncated capture). The previous fallback
  to `parse_tool_call_to_map/1` would coerce an empty body into a fake
  `unknown({})` tool use surfaced to the caller. Real parse errors (invalid JSON,
  non-object args, etc.) still fall through to the legacy heuristic.
- Qwen3-Coder tool-call format family (`qwen3-coder`). Qwen3-Coder (qwen3moe) emits
  tool calls in a nested-XML shape (`<tool_call><function=NAME><parameter=P>val</parameter></function></tool_call>`),
  not the Qwen2.5 JSON-in-tags shape the `qwen-xml` family handles, so its calls
  previously failed to parse (no usable arguments). New
  `barrel_inference_server_tool_format_qwen3_coder` renders the nested tool block and
  parses the nested calls (parameter values JSON-decoded when they round-trip, kept as
  raw strings otherwise). Pull-time detection (`detect_tool_call_format/1`) now picks
  `qwen3-coder` over `qwen-xml` when the template contains `<function=` (both share the
  `<tool_call>` markers), so future Qwen3-Coder pulls map correctly.
- Proactive idle-model eviction under memory pressure: `barrel_inference_server_model_evictor`
  implements the engine's `barrel_inference_model_evictor` behaviour, so the engine
  scheduler (with `unload_models_under_pressure => true`) can unload the
  least-recently-active idle model when cache eviction cannot relieve sustained
  pressure. Keepalive gains `unload_idle_sync/1`, which re-checks `active = 0` atomically
  inside the gen_server and returns `busy` (without unloading) if a request started
  since the candidate snapshot, so a model is never unloaded mid-request. The idle-model
  listing + registry wait used by the loader fit-check are shared via
  `barrel_inference_server_memory:idle_models/0` and `wait_unloaded/1`.
- Memory-aware model loading (opt-in via `memory_aware_loading => true`). Before a
  model loads, the loader estimates its resident footprint (mmapped weights from the
  GGUF file size + the f16 KV cache at the configured context, sized on
  `head_count_kv` so grouped-query attention is not overestimated) and compares it
  against available memory (the most restrictive of the GPU VRAM probe and the system
  memory probe). If it would not fit, the least-recently-active idle model is unloaded
  synchronously (waiting until it clears the registry) and the fit is re-checked;
  when nothing idle can be freed the load is rejected with 503 `model_would_oom`
  instead of letting llama.cpp OOM the box. Keepalive now tracks `last_active_ms` per
  model (exposed in `status/0`) to pick the unload victim. Off by default: the
  footprint-vs-free-memory comparison is approximate, so it is enabled only on
  memory-bound multi-model deployments. `model_load_memory_margin_b` (default 1 GiB)
  sets the headroom kept free above the estimate.
- Static system+tools prefix is checkpointed and pinned once per tool set. When a
  request carries tools, the pipeline computes the verified end-of-tools token offset
  (the longest common token prefix of a head-only render and the full render - no
  template-specific marker stripping needed) and forwards it as
  `Params.prefix_checkpoint_len`, so the engine writes + pins an `agent_prefix` KV
  checkpoint there. The big static prefix is then prefilled once and reused warm across
  turns and even fresh sessions, and survives cache eviction. The head render is
  memoized per transformed-head identity in a public ETS table. Verified live: a
  fresh-session second request reused 5552/5566 prompt tokens via the pinned prefix
  after a full GC dropped every unpinned row.

### Fixed

- Tool/chat requests no longer hang 60-180 s or crash the model. The hang was the
  sticky-seq admission *wedge*: with the engine's 1-sequence default a pinned
  session blocks every other session. Fixed by enabling `admission_on_full = error`
  (a full pool returns a fast retryable 503/529 instead of blocking) and by raising
  the seq pool. Crucially, the loader now sets `context_opts.kv_unified = true`:
  llama.cpp otherwise splits `n_ctx` into `n_ctx / n_seq_max` per sequence, so
  raising `n_seq_max` (to 4 by default for concurrency) would have cut a 32768
  context to ~8192 and made large agent prompts `decode_failed` (crash-loop). With
  the unified KV cache a single request may use the full `n_ctx` while up to
  `n_seq_max` sequences share that buffer - concurrency and large context at the
  same KV memory. A shared `barrel_inference_server_models:resolve_n_seq_max/1`
  (precedence `parameters.num_seq_max` > `loader.n_seq_max` > 4) drives both the
  engine seq pool and admission concurrency (`pool_policy_for/1`) so they never
  drift; existing models get the default without re-pulling.
- `/api/show` reports the context the model actually loads with (honours a
  `parameters.num_ctx` override set via `/api/edit`) instead of the raw manifest
  `context_size`, which left the override invisible. The loader resolves `n_ctx`
  through the same new `barrel_inference_server_models:effective_context_size/1`
  (precedence `parameters.num_ctx` > manifest `context_size`, capped by
  `max_context_size`) so the reported and loaded contexts never drift.

### Added

- Tool calling on `tool_choice = auto` uses native prompting + a tolerant
  streaming text parser (Ollama-style); `required`/`named` and a per-model
  `loader.tool_mode = grammar` opt-out use the GBNF grammar (forced,
  schema-enforced). A model whose manifest declares `loader.tool_call_format` +
  valid `loader.tool_call_markers`, implements the optional `render_prompt/2`
  callback, and is not pinned to `tool_mode = grammar` renders tools in its own
  format and free-decodes; `barrel_inference_server_tool_scan` then extracts tool
  calls from the generated text (configured markers, a generic `<tag>` wrapper, or
  bare JSON), validating the name against the request's tools and falling back to
  content otherwise. `render_prompt/2` ships for `qwen-xml`, `dsml` (DeepSeek),
  `llama-python-tag`, and `mistral-tool-calls`. The parser is bounded (capped
  holdback + region buffer) and does not enforce argument schemas - use
  `tool_mode = grammar` / `required` for that.
- Parallel tool calls. The model can emit several tool calls in one generation;
  all three handlers (`/v1/messages`, `/v1/chat/completions`, `/v1/responses`)
  accumulate them and surface N `tool_use` / `tool_calls` / function-call items
  (streaming and non-streaming). `parallel_tool_calls = false` (and Anthropic
  `tool_choice.disable_parallel_tool_use`) caps the turn to the first call.
  Server-side executor calls in one turn run concurrently via a coordinator
  (`barrel_inference_server_tool_batch`) and re-infer once; a mixed batch runs the
  server calls and continues the turn (client calls deferred to that
  continuation), so a turn never both continues and finishes.
- Embeddings support for embedding GGUFs. The pull pipeline detects embedding
  models from GGUF metadata (`barrel_inference_server_gguf:is_embedding_model/1`:
  a declared `*.pooling_type`, or a bidirectional-encoder architecture like
  `bert`/`nomic-bert`/`jina-bert`/`gte`) and marks the manifest `loader.embeddings`.
  The loader then opens the context in embeddings mode (`context_opts.embeddings`),
  so `/v1/embeddings` and `/api/embed` return vectors instead of 501. A Modelfile
  `PARAMETER`/`/api/edit` can set `embeddings` explicitly. Embedding models are
  embeddings-only (chat to them errors).
- Default model aliases `fast` -> `coder-7b:main` and `big` -> `qwen3-coder:30b`.

### Fixed

- Pulled manifests cap the default context at 32768 instead of baking the model's
  full native context (e.g. 262144). A large-context model no longer allocates tens
  of GB of KV by default and trips `system_memory_high_watermark`; raise it per-model
  via `/api/edit num_ctx` or the server-wide `max_context_size`.
- Heavy tool-grammar requests no longer crash-loop. `engine_call_timeout_ms` is
  raised to 120000 so a large model plus a large MCP tool grammar can compile and
  prefill during admission, and a timed-out engine worker is now killed instead of
  left running. New `barrel_inference_engine_admit_duration_seconds` histogram
  (labelled by op `infer`/`continue`) makes admission latency observable, with a
  slow-admit warning log.
- `pull` now registers a manifest even when the client disconnects or the
  request times out mid-download. Persistence moved off the HTTP handler into
  a supervised per-pull coordinator (`barrel_inference_server_pull`), so a
  completed download is never orphaned. Previously a multi-GB download could
  outrun cowboy's `idle_timeout`, the handler died before the fetch finished,
  and the blob landed in the cache with no manifest (so `list` showed nothing).
- The non-streaming pull path returns `504` on timeout while the download
  continues in the background, rather than losing the manifest.
- `barrel_inference_server_models_store:write_atomic/2` returns `{error, _}` on
  an unwritable cache dir instead of crashing.
- CLI `barrel-inference pull` exits non-zero when the stream reports an error
  (was always `0`).

### Barrel Inference 0.5.0 + tool-call exact-replay

- Bumped to Barrel Inference 0.5.0 (`{barrel_inference, "0.5.0"}` in `rebar.config`).
  v0.5 exposes per-model `tool_call_markers`, the
  `{tool_call_delta, _}` / `barrel_inference_tool_call_end` streaming wire,
  greedy-on-syntax sampling, sticky-seq KV reuse (`session_id` on
  `infer/4`, `end_session/2`), and the `prefill_only/3` cache-
  warming primitive.
- `loader.tool_call_markers` plumbed from the manifest into the
  Config map passed to `barrel_inference:load_model/2`, mirroring the
  existing `thinking_markers` path. Required keys `start` / `end`;
  optional `payload_start` / `payload_end`.
- New `barrel_inference_server_tool_format` behaviour and registry. Each
  model family ships a module implementing `parse/1` (FullBin ->
  `#{name, arguments}`) and `canonicalise/1` (the reverse). The
  registry resolves a canonical model id via the manifest's
  `loader.tool_call_format` field.
- Five built-in format families shipped in the default registry,
  covering the major open-weights backends:
  - `qwen-xml` (Qwen3 / Qwen2.5: `<tool_call>{...}</tool_call>`).
    Tolerates Hermes-style string `arguments`.
  - `dsml` (DeepSeek-V3 / R1:
    `<｜tool▁call▁begin｜>function<｜tool▁sep｜>NAME\n\`\`\`json\n{...}\n\`\`\`<｜tool▁call▁end｜>`).
    Tolerates batch wrapper, missing type prefix, missing fence.
  - `llama-python-tag` (Llama 3.1 / 3.2 / 3.3:
    `<|python_tag|>{"name":..., "parameters":...}<|eom_id|>`).
    Accepts `arguments` as well as `parameters`.
  - `mistral-tool-calls` (Mistral / Mixtral v3:
    `[TOOL_CALLS][{"name":..., "arguments":...}]</s>`). Returns
    the first call from a multi-call array; multi-call extraction
    is a documented follow-up.
  - `bare-json` (fallback for models that emit raw JSON without
    delimiters).
- New `barrel_inference_server_tool_replay` DETS-backed exact-replay store
  (supervised gen_server). Public ETS table for the O(1) hot-path
  read; sibling DETS file under `<cache_root>/replay/replay.dets`
  persists writes across restarts; periodic gc evicts rows past
  the TTL. Configuration knobs: `tool_replay_dir`,
  `tool_replay_ttl_ms` (default 30 days),
  `tool_replay_gc_interval_ms` (default 1h). All optional with
  sensible defaults.
- Both `/v1/messages` and `/v1/chat/completions` consume the v0.5
  tool-call wire when the model has `tool_call_markers` configured:
  every `barrel_inference_tool_call_end` triggers `tool_format:parse/2`, a
  fresh `toolu_...` id is minted, the parsed JSON + raw `FullBin` +
  model id are persisted in the replay map, and the corresponding
  Anthropic SSE frames (`content_block_start` / `input_json_delta`
  / `content_block_stop`) or OpenAI `chat.completion.chunk` with
  `tool_calls` are emitted. The legacy `mode = tool_buffer` first-
  byte heuristic stays as the fallback for models without
  `tool_call_markers` set.
- Render path in `barrel_inference_server_pipeline` walks the message
  history before `apply_chat_template/2` and consults the replay
  map for every prior `tool_use` block. Outcome lands on the new
  `barrel_inference_tool_replay_lookups_total` counter, labelled by `model`
  and `result` (`hit` / `miss` / `no_format`). Byte-exact splice
  awaits an engine-side ask (return-rendered-string variant of
  `apply_chat_template/2` or a verbatim content-block escape);
  tracked locally and documented in the asks prompt.

### Sticky-seq session id derivation + engine pin

- New `barrel_inference_server_session:derive/2` that yields a stable
  `session_id` for every request via a layered chain:
  `x-conversation-id` header > `metadata.user_id` >
  `base64(sha256(model || first user message bytes))`. Stamped
  onto `#barrel_inference_request{}` in both handlers' fast phase. Per-
  request stable id without requiring the SDK to send an explicit
  conversation header.
- Engine pin live: `build_params/1` now forwards the derived id
  on `Params.session_id` to `barrel_inference:infer/4`. The engine pins
  the seq_id across turns so a continuing conversation truncates-
  and-prefills in place on warm KV cells instead of restoring
  from disk.
- `{error, sticky_busy}` (two concurrent admits on the same
  session) maps to 503 with retry-after; the Anthropic handler
  remaps 503 to 529 so SDKs honour the documented backoff.
- Handler `cleanup/1` calls `barrel_inference:end_session/2` only when the
  request was cancelled mid-flight (`received_done = false`).
  Cleanly-completed turns leave the pinned session alive for
  cross-turn KV reuse.
- **Operational note**: with sticky pinning enabled, the engine's
  `context_opts.n_seq_max` (default 1) must exceed the expected
  concurrent-session count. A pinned session occupies a seq even
  between its turns; with `n_seq_max=1` and traffic from more than
  one session, admission deadlocks. Set
  `n_seq_max => N` on the model's load config (typical N = 4 or
  matching the queue's `concurrency`).

### Cache-reuse profile (TinyLlama-1.1B, 3-turn conversation)

`test/barrel_inference_server_real_model_SUITE.erl:multi_turn_cache_delta_profile/1`
drives a stable-session three-turn conversation and logs the
per-turn `cache_read_input_tokens` / `cache_creation_input_tokens`:

| Turn | input | output | cache_read | cache_creation |
| --- | --- | --- | --- | --- |
| 1 | 21 | 32 | 0 | 53 |
| 2 | 73 | 32 | **0** | 105 |
| 3 | 125 | 32 | 64 | 93 |

Turn 2 sees zero sticky reuse even with `Params.session_id` pinned.
The chat-template re-renders the first user turn differently in a
multi-turn context, so the engine's strict-prefix check fails and
admits cold. Turn 3 catches up via the disk cache (read=64).

This rules out `prefill_only/3` server-side cache warming
(originally PR 8): the bottleneck is **token-level prefix
divergence from the chat template**, not lack of an explicit
`parent_key` hint. The engine's natural longest-prefix walk on
admit already finds every available reuse row; an explicit
`prefill_only` call would compute the same prefix-match
and arrive at the same `read` count. PR 8 is closed as wontfix.

The leverage point is upstream: a chat-template rendering that
keeps leading-turn bytes stable across single- and multi-turn
calls, OR an engine-side primitive that splices the prior turn's
stored tokens verbatim into the new prompt (effectively the
verbatim-content escape already proposed for tool-call replay).
Captured in `/Users/benoitc/Projects/barrel_inference_anthropic_support_prompt.md`.

### Barrel Inference 0.6.0: caller-asserted continuation (`continue/3`)

The leverage-point ask above landed upstream as
`barrel_inference:continue/3`: the caller passes `(Model, SuffixTokens,
Opts)`, the engine prefills only the suffix on top of the
session's stored tokens without verifying the prefix. Two-PR
integration:

- Bump `rebar.config` to Barrel Inference 0.6.0. The new surface also
  carries `cache_hit_kind = continuation` to make the call-path
  distinguishable from engine-verified `sticky` reuse in Stats.
- New `barrel_inference_server_session_state` (supervised gen_server +
  public ETS) caches `{Model, SessionId} -> committed_tokens`.
  No disk persistence; restart drops the count and the next
  turn falls back to a full `infer/4`.
- Pipeline `accept_tokens/2` arms a continuation slice when a
  prior count is on file:
  `lists:nthtail(N, NewTokens)` becomes the suffix passed to
  `barrel_inference:continue/3`. First-turn / no-state requests still
  take the `infer/4` path.
- `{error, no_session}` from `continue/3` (TTL eviction, server
  restart, end_session-from-cancel) clears the stale local
  state and retries with the full token list via `infer/4`.
- Both handlers stash `committed_tokens` from `barrel_inference_done`
  Stats; `maybe_end_session/1` on cancel-mid-flight clears the
  local entry alongside the engine's.

Profile against TinyLlama-1.1B with `continue/3` live:

| Turn | input | output | cache_read | cache_creation |
| --- | --- | --- | --- | --- |
| 1 | 21 | 32 | 0 | 53 |
| 2 | 73 | 32 | **53** | 52 |
| 3 | 125 | 32 | **105** | 52 |

Every turn after the first reuses the predecessor's entire
committed state. `cache_creation` collapses to roughly the new
tail plus the generated output. The
`multi_turn_cache_delta_profile/1` CT case now asserts `Read2 > 0`
and `Read3 > Read2` so a slicing or state regression fails the
build.

**Risk**: the slice is **optimistic** - `continue/3` does not
verify that the suffix is the correct continuation of the
engine's stored prefix. If a model's chat template re-renders
prior turns differently across turns (different role-marker
bytes), the model emits garbage tokens on the continuation path.
The `cache_hit_kind = continuation` reported in Stats makes this
diagnosable. TinyLlama is stable; production models need a
per-model test against `multi_turn_cache_delta_profile/1` before
relying on continuation.

## [0.1.0] - 2026-05-11

Initial public release. OpenAI-, Anthropic-, and Ollama-compatible
HTTP server on top of `barrel_inference`.

### OpenAI surface

- `POST /v1/chat/completions` (streaming + non-streaming)
- `POST /v1/completions`
- `POST /v1/embeddings`
- `GET  /v1/models[/:id]` with alias passthrough
- Tool / function calling via grammar-constrained sampling. Tool
  arrays converted to JSON Schema then to GBNF and passed as the
  `grammar` field on `barrel_inference:infer/4`. Tool-call output buffered
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
- GGUF metadata reader (`barrel_inference_server_gguf`, pure Erlang, no
  NIF). Extracts architecture, family, parameter size,
  quantisation, context length, embedding length, chat template
  at pull time. Stored verbatim in the manifest.
- Manifest Modelfile overrides: `system`, `template`,
  `parameters` (which `loader` merges into the
  `barrel_inference:load_model/2` opts).

### Inference plumbing

- Per-model loader: `barrel_inference_server_loader` spawns a monitored
  worker for `barrel_inference:load_model/2` so the gen_server stays
  responsive while a load is in flight. Subscribers receive
  `{barrel_inference_load_progress, ModelId}` every 2 s and
  `{barrel_inference_load_done, ModelId, ok | {error, _}}` exactly once.
- Pipeline forwards load progress as `{pipeline, loading, _}`;
  chat handlers emit `: loading\n\n` SSE comments and Anthropic
  `event: ping` events so clients see activity during multi-second
  loads.
- Per-model keepalive (`barrel_inference_server_keepalive`) with active
  request counter. Eviction timer only arms when active count
  reaches zero, so long generations never trigger a mid-stream
  unload.
- Per-model FIFO semaphore queue with `pool_exhausted` returning
  429. `concurrency`, `depth`, `timeout_ms` configurable per model.
- Cancel-on-disconnect: TCP close fires `terminate/3`, which calls
  `barrel_inference:cancel/1`, releases the queue slot, kills the pipeline
  worker.
- Cowboy listener `idle_timeout` bumped to 30 min (configurable
  via `{idle_timeout_ms, _}`) so long fetches / loads do not get
  closed at cowboy's default 60 s.
- Loader `manifest_to_config/1` caps `context_size` at
  `max_context_size` (default 4096) so models advertising 128 K
  contexts in their GGUF do not OOM at load time.
- Pipeline wraps every call into `barrel_inference` in try/catch; a
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

- `barrel_inference` escript (`rebar3 escriptize` -> `_build/default/bin/barrel_inference`).
  Subcommands: `pull`, `list` (ls), `ps`, `show`, `rm` (delete),
  `copy` (cp), `search`, `run`, `embed`, `unload`, `version`, `help`.
- Talks to the daemon over HTTP. Base URL via `BARREL_INFERENCE_HOST`
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
