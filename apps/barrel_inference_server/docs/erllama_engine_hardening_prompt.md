# Prompt: harden the erllama engine against decode wedges

Drop this verbatim into a fresh Claude Code session pointed at the
sibling `erllama` repo (`/Users/benoitc/Projects/erllama`).

This is the **engine-robustness** companion to
`erllama_nif_hardening_prompt.md` (which covers SIGSEGV / input
validation). That one stops bad inputs from killing the BEAM; this one
stops a *wedged decode* from hanging the model process and forcing a
full reload.

---

# Harden the erllama engine against decode wedges

## Context

The downstream `erllama_server` runs an agentic tool "continue-loop"
that re-infers several times per request (model calls a tool -> server
runs it -> result fed back -> generation continues). Running this on a
30B model on Apple Metal surfaced reliability gaps that only the engine
can fix. The server already mitigates from the outside: a bounded
`gen_statem` call timeout, `reset_session/2`, escalation to
`unload/1`+reload, a per-model queue, and request-level timeouts. The
items below are what's left, in priority order. Observed on erllama
0.7.0 (which already added `reset_session/2`, `{decode_failed, Rc}`,
and `n_seq_max`/`available_seqs` in `model_info`).

## 1. Cold-admit wedge / unbounded, non-interruptible decode (CRITICAL)

**Symptom.** Under repeated cold admissions (fresh seq, no warm
prefix) the `gen_statem:call` into the model process never returns: a
decode step wedges. The server's bounded call times out
(`engine_unresponsive`), `reset_session/2` returns `not_found`
(it's a global/context wedge, not per-session), and the only recovery
is `unload/1` + cold reload of the whole model. Reproducible: the 2nd
cold infer of a growing prompt on the 30B reliably wedges.

**Asks:**
- Bound each decode/sampling step at the NIF boundary so a single
  `llama_decode` cannot block the dirty-NIF thread indefinitely;
  return `{error, decode_timeout}` instead of hanging.
- Make the decode loop interruptible: the model `gen_statem` must stay
  responsive to `cancel/1` and a watchdog while a decode is in flight
  (today a wedged decode blocks the call, so cancel can't land).
- Context watchdog + in-place recovery: detect a stalled context
  (no token progress within a budget) and reset/reinit it without
  requiring the supervisor to `unload`+cold-reload the entire model.
- Investigate why a fresh-seq cold prefill is more wedge-prone than a
  warm `continue/3` and harden that path.

Constraint reminder: do NOT wrap `llama_decode` in `setjmp`/`longjmp`
(it allocates internally); use a cooperative cancel flag / bounded
budget the decode loop polls.

## 2. `continue/3` must apply `Params.grammar` (GBNF) like `infer/4`

**Symptom.** In the continue-loop, a continued round issued with
`tool_choice = required` (a GBNF that permits only a tool call)
produced free-form text instead of a constrained tool call. This
indicates `continue/3` does not install/honor `Params.grammar`.

**Ask.** `continue/3` must apply the sampling grammar identically to
`infer/4`, so `response_format` / `tool_choice` constraints hold on
continuation rounds, not just the first turn.

## 3. Byte-exact continuation: expose generated token ids

**Context.** To continue a turn after a tool result, the server wants
to feed the model's prior turn back as a verified suffix for
`continue/3` without re-tokenizing detokenized text (which drifts and
mis-slices into garbage). `erllama_server`'s `AGENTS.md` already notes
"byte-exact splice awaits an engine-side ask."

**Asks (either suffices):**
- Surface the exact generated token ids for a turn (in `erllama_done`
  Stats, or via the existing `{erllama_token_id, _, _}` stream).
- Or accept a caller-supplied committed-token transcript on
  `continue/3` and verify/prefill against it, returning an explicit
  mismatch error rather than silently producing garbage.

This makes warm KV reuse reliable for tool-augmented multi-round turns,
which also sidesteps issue #1 (no cold re-infer per round).

## 4. Structured errors on every NIF failure path

`{decode_failed, Rc}` (0.7.0) is good. Audit the remaining NIF entry
points (load, tokenize, apply_chat_template, embed, decode, sample) so
every failure returns a structured `{error, _}` and never crashes or
hangs the owning `gen_statem`.

## 5. `n_seq_max` / sticky-seq deadlock ergonomics

The front end must set `context_opts.n_seq_max >=` the concurrent
session count or sticky pinning deadlocks when a second session
admits (engine default of 1 is a footgun). Either auto-raise
`n_seq_max` to satisfy a sticky admit, or return a structured
`{error, seq_capacity}` instead of blocking. Pair with the
`available_seqs`/`n_seq_max` diagnostics already in `model_info`.

## Verification

```bash
rebar3 fmt --check && rebar3 compile && rebar3 eunit && rebar3 ct \
  && rebar3 lint && rebar3 dialyzer && rebar3 xref
```

Add tests (gated on `LLAMA_TEST_MODEL`):
- N cold admits of a growing prompt: none wedge (today fails ~2nd).
- `continue/3` under a `required`-tool grammar emits a grammar-valid
  tool call.
- `cancel/1` lands within a bounded time even mid-decode.

## Constraints

- Keep NIF work on dirty CPU schedulers; no `setjmp`/`longjmp` around
  `llama_decode`.
- No new third-party deps.
- Project conventions per `AGENTS.md`: annotate only non-obvious *why*.
