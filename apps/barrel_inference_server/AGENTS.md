# Agents

Instructions for AI coding agents working on this project.

## Project Overview

Barrel Inference Server is the OpenAI- and Anthropic-compatible HTTP front
end for [Barrel Inference](https://github.com/barrel-platform/barrel_inference). One OTP
application, flat layout:

```
src/        Erlang sources (barrel_inference_server, barrel_inference_server_h_*,
            barrel_inference_server_translate, barrel_inference_server_grammar, ...)
include/    Shared records (barrel_inference_server.hrl)
test/       Common Test suites
config/     sys.config, vm.args
```

Barrel Inference Server depends on `barrel_inference` as a hex/git dep and never reaches
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
rebar3 ct --suite=barrel_inference_server_smoke_SUITE      # One suite
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
barrel_inference_server_sup (rest_for_one)
├── barrel_inference_server_disk_cache    DETS-backed KV cache file
├── barrel_inference_server_registry      via callback for {queue, ModelId}
├── barrel_inference_server_config        aliases + load policy + persistent_term
├── barrel_inference_server_loaders_sup   per-model loader processes
├── barrel_inference_server_queues_sup    per-model semaphore queues
├── barrel_inference_server_fetch_sup     manifest / blob download workers
├── barrel_inference_server_fetch_srv     fetch coordinator
├── barrel_inference_server_keepalive     per-model idle-eviction timer
└── barrel_inference_server_listener_mon  Cowboy listener + restart watch
```

Pipeline workers (`barrel_inference_server_pipeline`) are NOT supervised: each
one is spawned linked from a Cowboy handler in `init/2` and dies
with its handler. The supervisor tree only owns long-lived
infrastructure.

### Request lifecycle

1. **Fast phase** (in `init/2`): read body, decode JSON, translate
   to `#barrel_inference_request{}`, resolve alias. Failures here become JSON
   4xx via `cowboy_req:reply/4` before the handler ever enters
   `cowboy_loop` mode.
2. Spawn a linked **pipeline worker**. Handler returns
   `{cowboy_loop, Req, State#st{phase = waiting_load}, hibernate}`.
3. Worker drives the slow phase in order:
   `ensure_loaded` -> `apply_chat_template` (or `tokenize` for
   legacy completions) -> grammar build -> queue acquire ->
   `barrel_inference:infer/4`. Progress messages flow back to the handler:
   `{pipeline, loaded}`, `{pipeline, templated, _}`,
   `{pipeline, queued}`, `{pipeline, admitted, Ref, Slot}`, or
   `{pipeline, error, HttpStatus, Reason}`.
4. **Streaming**: handler stays in `cowboy_loop`, receives
   `{barrel_inference_token, Ref, _}` messages, emits SSE chunks. Tool-call
   mode (`mode = tool_buffer`) buffers grammar-mode JSON and emits
   one final `tool_calls` (OpenAI) or `content_block_*` (Anthropic)
   frame on `{barrel_inference_done, _, _}`.
5. **Non-streaming**: same handler shape, accumulates tokens into
   `buf_text`, replies once on `{barrel_inference_done, _, _}`.
6. **Cancel-on-disconnect**: Cowboy fires `terminate/3` on TCP
   close, which calls `barrel_inference:cancel/1`, releases the queue slot,
   kills the pipeline worker.

### Per-model semaphore queue

`barrel_inference_server_queue` is a pure resource limiter: tracks a slot
count plus a FIFO of waiters. It does not call barrel_inference and does not
see `barrel_inference_token` messages. The handler is the slot holder; on
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

`barrel_inference_server_translate` is a pure module: no `barrel_inference:*`, no
`cowboy_*`, no I/O. It maps:

- OpenAI `/v1/chat/completions` -> `#barrel_inference_request{}`
- OpenAI `/v1/completions` -> `#barrel_inference_request{}`
- OpenAI `/v1/embeddings` -> `#{model, inputs}`
- Anthropic `/v1/messages` -> `#barrel_inference_request{}`

And the reverse: `#barrel_inference_request{}` plus per-response state ->
the JSON-encodable response or per-event SSE frame for both APIs.

The translator does NOT tokenise. The handler's pipeline calls
`barrel_inference:apply_chat_template/2` (chat / messages) or
`barrel_inference:tokenize/2` (legacy completions) to produce token ids.

### Tool-call parsing (autoparser)

Tool calls are extracted at done by llama.cpp's `common_chat_parse`
via `barrel_inference:chat_parse/3`. The pipeline renders the prompt
through `barrel_inference:chat_apply/2` (the autoparser's chat
templates apply path), which returns a `ParamsRef` carried admit ->
done on `{pipeline, templated, Tokens, ParamsRef}`. At done the
handler bridge `barrel_inference_server_autoparser:maybe_extract/4`
parses the buffered response text into structured tool calls.
HTTP wire shape is unchanged (OpenAI `tool_calls`, Anthropic
`tool_use`, Responses `function_call`). For tools requests grammar
is left empty (model decodes freely); response_format / format
without tools still drives GBNF via
`barrel_inference_server_grammar:from_response_format/1`.

### Weight residency

A `loader.weight_residency` manifest field picks how a model's weights
live in memory. Four modes ship: `eager` (default; kernel reads
ahead), `lazy` (`MADV_RANDOM`; pages fault in on first touch),
`pinned` (mlock the whole file), and `lazy_then_pin_resident` (load
lazy, then mlock the resident set after the first request via the
scheduler's hook in `finish_req`). The loader's `residency_to_opts/1`
(`src/barrel_inference_server_loader.erl`) maps each mode to a
`(use_mmap, use_mlock, prefetch)` triple plus, for the
`lazy_then_pin_resident` case, the `pin_resident_after_first_request`
flag the engine reads at init.

Resolution precedence: Modelfile `PARAMETER weight_residency` >
manifest `loader.weight_residency` > app env
`weight_residency_default` (surfaced by
`barrel_inference_server_config:weight_residency_default/0`,
default `eager`). Unknown values fall back to the default with a
`logger:warning/2`.

Observability: the Prometheus gauge
`barrel_inference_resident_bytes{model=...}` reports
`mincore`-resident bytes per loaded model, sampled per `/metrics`
scrape by `barrel_inference_server_metrics:sample_resident_bytes/0`.
Use it together with the process RSS to see whether the lazy mode is
actually keeping pages off the BEAM's account.

Operator-facing details live in `guides/weight_residency.md`; the
real-model bench writeup is at
`apps/barrel_inference/internals/weight-residency-bench.md`.

### Sticky-seq session id

`barrel_inference_server_session:derive/2` yields a stable `session_id`
binary for each request via a layered chain:
`x-conversation-id` header > `metadata.user_id` >
`base64(sha256(model || first user message bytes))`. The id is
stamped onto `#barrel_inference_request.session_id` in both handlers'
fast phase and forwarded to `barrel_inference:infer/4` on
`Params.session_id`. The engine pins the seq_id across turns so a
continuing conversation truncates-and-prefills in place on warm
KV cells.

`{error, sticky_busy}` from concurrent admits on the same session
maps to 503 (529 on the Anthropic surface) with retry-after.
Handler `cleanup/1` calls `barrel_inference:end_session/2` only when the
request was cancelled mid-flight (`received_done = false`);
cleanly-completed turns leave the session pinned for the next
turn.

Operators must set `context_opts.n_seq_max` on the model's load
config to **at least** the expected concurrent-session count
(typical: match the per-model queue concurrency). The engine
default of 1 deadlocks under sticky pinning the moment a second
session tries to admit.

### Continuation path (`barrel_inference:continue/3`, v0.6+)

For chat templates whose multi-turn render diverges at the head
from the single-turn render, the engine's prefix-equality check
on the `sticky` path fails and the session falls back to cold
admit. To work around this, barrel_inference 0.6 ships `continue/3` (a
caller-asserted variant of admission: the caller passes only
the new suffix, the engine prefills it on top of the session's
stored state without verification).

`barrel_inference_server_session_state` (supervised gen_server + public
ETS, keyed on `{Model, SessionId} -> [token_id()]`) caches the
session's exact committed token-id list. barrel_inference 0.8 reports the
generated token ids (`generated`) in each turn's `barrel_inference_done`
Stats; the handler's `record_session_committed/2` calls
`barrel_inference_server_session_state:record/4`, which stores
`PromptTokens ++ generated` only when its length agrees with the
engine's `committed_tokens` count (otherwise the list cannot be
trusted and nothing is stored). The pipeline's
`maybe_arm_continuation/2` then routes through `continue/3` only
when the stored list is a strict `lists:prefix/2` of the freshly
rendered prompt; the new suffix is `lists:nthtail(length(Committed),
NewTokens)` and `Committed` is forwarded as `expect_committed` so
the engine re-validates the splice.

Failure modes (all fall back to a correct full `infer/4`, never
garbage):
- `{error, no_session}` (TTL eviction, server restart, prior
  cancel-mid-flight): pipeline clears the stale local state and
  retries with the full token list.
- `{error, {transcript_mismatch, _}}`: the engine's stored
  context disagrees with our `expect_committed`. Clear + full
  `infer/4`.
- Stored list is not a prefix of the new render (chat template
  re-renders prior turns differently): continuation is not armed;
  the turn admits cold. `multi_turn_cache_delta_profile/1` against
  a production model shows how often the warm path is kept.

### Test Organization

- `test/barrel_inference_server_translate_SUITE.erl`: schema translation,
  request and response directions, both APIs.
- `test/barrel_inference_server_grammar_SUITE.erl`: GBNF generation for
  response_format / JSON Schema subset.
- `test/barrel_inference_server_smoke_SUITE.erl`: HTTP surface boot probe -
  health, ready, models, metrics, embeddings/chat error paths,
  CORS, request-id.
- `test/barrel_inference_server_session_tests.erl`: eunit for the layered
  session-id derivation.

A real-model CT suite (gated on `LLAMA_TEST_MODEL`, mirroring
barrel_inference's pattern) is planned for v0.2.

## Linting Notes

Elvis rules and erlfmt config live in `rebar.config`. Project plugins
are pinned to specific versions (erlfmt 1.7.0, rebar3_lint 4.1.1).
Per-module ignores are documented inline.

## Coding conventions

- Default to writing no comments. Only annotate non-obvious *why* (a
  hidden constraint, an invariant, a workaround).
- Pure modules for things that are pure: translate and grammar do
  not touch barrel_inference or Cowboy.
- Long-lived infrastructure goes in the supervisor tree; per-request
  state goes on a linked process that dies with the handler.
- `instrument` (github.com/benoitc/instrument) is the metrics layer.
  Never use any third-party prometheus library.
- Hot path is one `persistent_term:get/1` plus one NIF call per
  metric increment.

## What to avoid

- No reaching into llama.cpp from this app. Use the barrel_inference public
  API (`barrel_inference:infer/4`, `barrel_inference:cancel/1`, `barrel_inference:tokenize/2`,
  etc.).
- No body-shape gating after the slow phase has started. Caps run
  in `barrel_inference_server_translate` before `cowboy_req:stream_reply/2`.
- No `next_event` in the handlers. The decode loop in
  `barrel_inference_model` already uses `gen_statem:cast(self(), decode_step)`
  so cancel and external messages interleave fairly between tokens.
- No global atom interning of user-supplied identifiers. Models are
  binaries throughout; `barrel_inference_registry` is the via callback.
- No silent failure on `cowboy:start_clear`. The listener_mon
  gen_server monitors the returned pid and restarts on death.

## When in doubt

Re-read the test suite for the area you're touching. The HTTP
contract (status codes, error envelopes, SSE shapes) is captured in
the smoke and translate suites; the GBNF grammar shape is captured
in the grammar suite. Surface tension with existing tests to the
human reviewer before changing behaviour.
