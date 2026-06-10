# Feature backlog

Outstanding items from approved plans that have not landed yet. Each
entry says what was promised, where the plan came from, and the
current state. Sorted by maturity (closest to shippable on top).

## Promised, not delivered

### 1. Autoparser per-request synthesis cost

Source: autoparser-primary plan (PR #32), "Out of scope" section.

Today every chat request pays a fresh `common_chat_templates_apply`,
which synthesises a PEG parser into `common_chat_params` on every
call. The synthesis depends on `(tools, tool_choice,
parallel_tool_calls)` only; messages just drive the jinja render. The
plan flagged a follow-up that splits the upstream entry into a
render-only call and a params-build call, then caches the params by
`{ModelId, ToolsHash, tool_choice, parallel_tool_calls}` so repeat
turns reuse the parser arena.

### 2. Multi-turn `tool_use` re-render verification

Source: autoparser-primary plan (PR #32), "Verification" section.

The plan committed to a manual reviewer step: confirm that a prior
`tool_use` block in the assistant history is re-rendered correctly via
the chat template's own embed of `tool_calls`. The single-turn round
trip was spot-checked on Devstral 24B during the bench; the multi-turn
case has not been exercised end to end.

### 3. Bench escript in repo

Source: `apps/barrel_inference/internals/weight-residency-bench.md`
references `/tmp/weight_residency_bench.escript`.

The escript that produced the table lives in `/tmp` on a maintainer
laptop. Anyone reproducing has to recreate it from memory. Should land
as a scripts/bench fixture so a clean checkout can rerun the
measurement.

### 4. Server `AGENTS.md` does not document recent additions

The contributor guide at
`apps/barrel_inference_server/AGENTS.md` covers up to the autoparser
refactor but does not mention `weight_residency`, the
`barrel_inference_resident_bytes` gauge, the
`weight_residency_default` app env, or the `lazy_then_pin_resident`
mode. Operators reading the guide will not know these exist.

### 5. `sys.config` example for `weight_residency_default`

The app env is documented in the operator guide but is not present in
any of the example configs under `config/sys.config`. Operators
copying the example will not know the key exists.

## Acknowledged-deferred, listed as known follow-ups

### 6. `nif_chat_msg_diff` streaming-delta entry point

Source: autoparser-primary plan.

Would let the handler extract structured tool calls mid-stream instead
of at done. Not needed by today's surface (handlers parse only at
done); kept on the list for completeness.

### 7. Per-family Erlang fallback for autoparser-uncovered templates

Source: autoparser-primary plan.

If a template's tool block diff fails to autoparse, the response
surfaces as text. The plan accepted the rare miss; no action unless a
real-world model surfaces a failure mode.

### 8. Per-layer residency (attention pinned, FFN lazy)

Source: weight_residency plan, "Out of scope".

Would need llama.cpp per-tensor mapping introspection to mlock just
the attention tensors while letting FFN rows page in lazily. Maps
closer to the AFM3 "shared experts always loaded, routed experts
swapped" pattern than today's whole-file knob.

### 9. `lazy_then_pin_resident` iterative refinement

Source: weight_residency plan, queued as v2.

Today the mode runs once on first `finish_req`. A second pass after
every N requests would grow the pinned set as new prompts touch new
weight pages, asymptotically converging to "every page that was ever
needed". Adds RSS over time; better Apple-fit but bigger blast radius.

### 10. LoRA tier caching

Source: cross-reference from broader memory pointer
`[[adapter-lora-tier]]`.

The runtime's `apply_adapters/2` backend hook already exists; the
follow-up would let LoRAs live in the same disk / ram_file tier system
as KV slabs so different LoRAs per request never re-download.

## Local-dev tax

### 11. OTP-29 `h1` dep `catch` warning

`rebar3 compile` fails locally on OTP 29 boxes because the `h1` HTTP
client uses the deprecated `catch X` form. CI on OTP 28 hides it.
Workaround so far is manually invoking erlc with
`+nowarn_deprecated_catch`. Real fixes:

- A per-dep `overrides` block in the umbrella `rebar.config` that
  injects `nowarn_deprecated_catch` into `h1`'s compile opts.
- Or: upstream a `try ... catch ... end` rewrite to `h1`.
