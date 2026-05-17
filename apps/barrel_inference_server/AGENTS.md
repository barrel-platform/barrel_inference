# Agents

Instructions for AI coding agents working on this project.

## Project Overview

erllama_server is the OpenAI- and Anthropic-compatible HTTP front
end for [erllama](https://github.com/erllama/erllama). One OTP
application, flat layout:

```
src/        Erlang sources (erllama_server, erllama_server_h_*,
            erllama_server_translate, erllama_server_grammar, ...)
include/    Shared records (erllama_server.hrl)
test/       Common Test suites
config/     sys.config, vm.args
```

erllama_server depends on erllama as a hex/git dep and never reaches
into llama.cpp directly. The HTTP shape, the GBNF tool-call grammar
generation, the request lifecycle (admit, queue, stream, cancel),
and the metrics/Prometheus exposure all live here.

Authoritative behaviour is encoded in the test suites under `test/`
(Common Test) and the module docstrings. The README has the public
API tables and configuration reference.

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # Auto-format (always run first)
rebar3 compile      # Must compile cleanly (warnings_as_errors)
rebar3 ct           # Common Test suites
rebar3 lint         # Elvis linter
rebar3 dialyzer     # Type checking
rebar3 xref         # Cross-reference analysis
```

## Build & Development Commands

```bash
rebar3 compile                                    # Build
rebar3 shell                                      # Boot a dev shell
rebar3 ct --suite=erllama_server_smoke_SUITE      # One suite
rebar3 release                                    # Build a release tarball
rebar3 fmt                                        # Auto-format (erlfmt)
rebar3 fmt --check                                # Format check, no writes
rebar3 lint                                       # Elvis linter
rebar3 dialyzer                                   # Type checking
rebar3 xref                                       # Cross-reference
```

## Architecture

### Supervision tree

```
erllama_server_sup (rest_for_one)
├── erllama_server_disk_cache    DETS-backed KV cache file
├── erllama_server_registry      via callback for {queue, ModelId}
├── erllama_server_config        aliases + load policy + persistent_term
├── erllama_server_tool_replay   DETS-backed exact-replay map for tool-call bytes
├── erllama_server_loaders_sup   per-model loader processes
├── erllama_server_queues_sup    per-model semaphore queues
├── erllama_server_fetch_sup     manifest / blob download workers
├── erllama_server_fetch_srv     fetch coordinator
├── erllama_server_keepalive     per-model idle-eviction timer
└── erllama_server_listener_mon  Cowboy listener + restart watch
```

Pipeline workers (`erllama_server_pipeline`) are NOT supervised: each
one is spawned linked from a Cowboy handler in `init/2` and dies
with its handler. The supervisor tree only owns long-lived
infrastructure.

### Request lifecycle

1. **Fast phase** (in `init/2`): read body, decode JSON, translate
   to `#erllama_request{}`, resolve alias. Failures here become JSON
   4xx via `cowboy_req:reply/4` before the handler ever enters
   `cowboy_loop` mode.
2. Spawn a linked **pipeline worker**. Handler returns
   `{cowboy_loop, Req, State#st{phase = waiting_load}, hibernate}`.
3. Worker drives the slow phase in order:
   `ensure_loaded` -> `apply_chat_template` (or `tokenize` for
   legacy completions) -> grammar build -> queue acquire ->
   `erllama:infer/4`. Progress messages flow back to the handler:
   `{pipeline, loaded}`, `{pipeline, templated, _}`,
   `{pipeline, queued}`, `{pipeline, admitted, Ref, Slot}`, or
   `{pipeline, error, HttpStatus, Reason}`.
4. **Streaming**: handler stays in `cowboy_loop`, receives
   `{erllama_token, Ref, _}` messages, emits SSE chunks. Tool-call
   mode (`mode = tool_buffer`) buffers grammar-mode JSON and emits
   one final `tool_calls` (OpenAI) or `content_block_*` (Anthropic)
   frame on `{erllama_done, _, _}`.
5. **Non-streaming**: same handler shape, accumulates tokens into
   `buf_text`, replies once on `{erllama_done, _, _}`.
6. **Cancel-on-disconnect**: Cowboy fires `terminate/3` on TCP
   close, which calls `erllama:cancel/1`, releases the queue slot,
   kills the pipeline worker.

### Per-model semaphore queue

`erllama_server_queue` is a pure resource limiter: tracks a slot
count plus a FIFO of waiters. It does not call erllama and does not
see `erllama_token` messages. The handler is the slot holder; on
`terminate/3` it calls `release/2`. Each acquire returns a unique
`WaiterRef = make_ref()` so timeouts cannot mis-fire across acquire
attempts.

### Per-model loader race fix

The loader's `start_load` self-message can fire before the awaiter's
`await` cast is processed. To prevent orphaned awaiters, the loader
stays alive on both success and failure - late awaiters read the
cached state. The config server's `'DOWN'` handler removes the
loader entry; an explicit retry would need a future `force_reload`
API.

### Schema translation

`erllama_server_translate` is a pure module: no `erllama:*`, no
`cowboy_*`, no I/O. It maps:

- OpenAI `/v1/chat/completions` -> `#erllama_request{}`
- OpenAI `/v1/completions` -> `#erllama_request{}`
- OpenAI `/v1/embeddings` -> `#{model, inputs}`
- Anthropic `/v1/messages` -> `#erllama_request{}`

And the reverse: `#erllama_request{}` plus per-response state ->
the JSON-encodable response or per-event SSE frame for both APIs.

The translator does NOT tokenise. The handler's pipeline calls
`erllama:apply_chat_template/2` (chat / messages) or
`erllama:tokenize/2` (legacy completions) to produce token ids.

### Tool-call grammar

`erllama_server_grammar:from_tools/2` converts the OpenAI/Anthropic
tools array into a GBNF grammar that `erllama:infer/4` accepts via
`Params.grammar`. `tool_choice = auto` emits
`text_response | tool_alt`; `required` omits the text branch;
`{named, _}` pins to a single tool; `none` returns no grammar.

### Tool-call exact replay (erllama 0.5)

When a model declares `loader.tool_call_markers` in its manifest,
erllama emits `{tool_call_delta, _}` deltas and one
`erllama_tool_call_end` per call instead of routing tool JSON
through the first-byte heuristic. The capture path lives in both
handlers' info/3 clauses:

1. `erllama_server_tool_format:lookup/1` is called once at admit
   time to resolve the model id to a `parse/1` + `canonicalise/1`
   module via `loader.tool_call_format`. Five families ship in
   the default registry: `qwen-xml`, `dsml`,
   `llama-python-tag`, `mistral-tool-calls`, `bare-json`. Adding
   a new family is one new `erllama_server_tool_format_<family>`
   module plus one entry in
   `erllama_server_config:default_tool_call_formats/0`.
2. On `erllama_tool_call_end`, the handler parses `FullBin` via
   the format module, mints a `toolu_...` id, and persists
   `{ToolId, Model, FullBin, Json}` in `erllama_server_tool_replay`
   (DETS-backed, ETS hot path). The Anthropic SSE
   (`content_block_start` / `input_json_delta` /
   `content_block_stop`) or OpenAI `chat.completion.chunk`
   `tool_calls` frame is emitted from the captured block.
3. `erllama_server_pipeline:apply_chat_template/1` walks the
   message history before rendering and consults the replay map
   for each prior `tool_use` block. Outcome lands on the
   `erllama_tool_replay_lookups_total` counter (label
   `result = hit | miss | no_format`). Byte-exact splice awaits
   an engine-side ask (see
   `/Users/benoitc/Projects/erllama_anthropic_support_prompt.md`).

### Sticky-seq session id

`erllama_server_session:derive/2` yields a stable `session_id`
binary for each request via a layered chain:
`x-conversation-id` header > `metadata.user_id` >
`base64(sha256(model || first user message bytes))`. The id is
stamped onto `#erllama_request.session_id` in both handlers'
fast phase and forwarded to `erllama:infer/4` on
`Params.session_id`. The engine pins the seq_id across turns so a
continuing conversation truncates-and-prefills in place on warm
KV cells.

`{error, sticky_busy}` from concurrent admits on the same session
maps to 503 (529 on the Anthropic surface) with retry-after.
Handler `cleanup/1` calls `erllama:end_session/2` only when the
request was cancelled mid-flight (`received_done = false`);
cleanly-completed turns leave the session pinned for the next
turn.

Operators must set `context_opts.n_seq_max` on the model's load
config to **at least** the expected concurrent-session count
(typical: match the per-model queue concurrency). The engine
default of 1 deadlocks under sticky pinning the moment a second
session tries to admit.

### Test Organization

- `test/erllama_server_translate_SUITE.erl`: schema translation,
  request and response directions, both APIs.
- `test/erllama_server_grammar_SUITE.erl`: GBNF generation, JSON
  Schema subset, tool_choice variants.
- `test/erllama_server_smoke_SUITE.erl`: HTTP surface boot probe -
  health, ready, models, metrics, embeddings/chat error paths,
  CORS, request-id.
- `test/erllama_server_tool_replay_SUITE.erl`: CT for the DETS-
  backed replay store (put/get round-trip, gc-evicts-expired,
  restart survival).
- `test/erllama_server_tool_format_tests.erl`,
  `..._dsml_tests.erl`, `..._llama_python_tag_tests.erl`,
  `..._mistral_tool_calls_tests.erl`, `..._bare_json_tests.erl`:
  eunit round-trip and tolerance for each shipped format family.
- `test/erllama_server_session_tests.erl`: eunit for the layered
  session-id derivation.

A real-model CT suite (gated on `LLAMA_TEST_MODEL`, mirroring
erllama's pattern) is planned for v0.2.

## Linting Notes

Elvis rules and erlfmt config live in `rebar.config`. Project plugins
are pinned to specific versions (erlfmt 1.7.0, rebar3_lint 4.1.1).
Per-module ignores are documented inline.

## Coding conventions

- Default to writing no comments. Only annotate non-obvious *why* (a
  hidden constraint, an invariant, a workaround).
- Pure modules for things that are pure: translate and grammar do
  not touch erllama or Cowboy.
- Long-lived infrastructure goes in the supervisor tree; per-request
  state goes on a linked process that dies with the handler.
- `instrument` (github.com/benoitc/instrument) is the metrics layer.
  Never use any third-party prometheus library.
- Hot path is one `persistent_term:get/1` plus one NIF call per
  metric increment.

## What to avoid

- No reaching into llama.cpp from this app. Use the erllama public
  API (`erllama:infer/4`, `erllama:cancel/1`, `erllama:tokenize/2`,
  etc.).
- No body-shape gating after the slow phase has started. Caps run
  in `erllama_server_translate` before `cowboy_req:stream_reply/2`.
- No `next_event` in the handlers. The decode loop in
  `erllama_model` already uses `gen_statem:cast(self(), decode_step)`
  so cancel and external messages interleave fairly between tokens.
- No global atom interning of user-supplied identifiers. Models are
  binaries throughout; `erllama_registry` is the via callback.
- No silent failure on `cowboy:start_clear`. The listener_mon
  gen_server monitors the returned pid and restarts on death.

## When in doubt

Re-read the test suite for the area you're touching. The HTTP
contract (status codes, error envelopes, SSE shapes) is captured in
the smoke and translate suites; the GBNF grammar shape is captured
in the grammar suite. Surface tension with existing tests to the
human reviewer before changing behaviour.
