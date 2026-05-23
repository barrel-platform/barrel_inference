# Prompt: harden the erllama NIF against SIGSEGV

Drop this verbatim into a fresh Claude Code session pointed at the
sibling `erllama` repo (`/Users/benoitc/Projects/erllama`).

---

# Harden the erllama NIF against SIGSEGV

## Context

The downstream `erllama_server` HTTP front end hit several BEAM-killing
segfaults when real clients (Claude Code, OpenAI SDK) sent oversized
prompts at Qwen2.5-7B on Metal. The server now does defensive
validation at the Erlang boundary, but the real fix belongs here:
`erllama_nif` should refuse bad inputs with a clean `{error, _}`
tuple rather than dereferencing past a buffer and killing the
entire BEAM.

These were the actual failure modes observed:

1. **Prompt with `n_tokens >= n_ctx`** — `nif_prefill` passes the
   full token list to `llama_batch_get_one` then `llama_decode`.
   When the prompt exceeds the context window the KV cache can't
   fit and llama.cpp dereferences off the end of the slab during
   the prefill graph. SIGSEGV.

2. **n_ctx defaulting to 512** — when the caller's `context_opts`
   map omits `n_ctx`, llama.cpp's default (512) wins. Any
   non-trivial prompt then hits failure mode 1. Combined with
   malformed chat-template args this produced an unrecoverable
   crash.

3. **`n_tokens > n_batch`** — same code path; if the caller passes
   a long prompt and a small `n_batch`, the single-decode call
   exceeds llama's batch size. Undefined behaviour at decode time.

Two non-segfault paths in the same module worth fixing in this pass:

4. `nif_apply_chat_template` raises `badarg` on non-binary content
   (Anthropic-style content blocks `[{type:"text",text:T}]`).
   Should return `{error, invalid_content}` rather than
   `enif_make_badarg`.
5. `llama_load_model_from_file` aborts via `GGML_ASSERT` on certain
   malformed GGUFs. Today erllama dies; should return
   `{error, malformed_gguf}` via the abort callback already wired
   (`set_abort_callback: call`).

## Files

- `c_src/erllama_nif.c` — the NIF surface. Most edits land here.
- `c_src/erllama_safe.cpp` — C++ wrappers that catch llama.cpp
  exceptions and translate to integer return codes. The pattern
  to extend.
- `src/erllama_nif.erl` — pure-Erlang side. No edits expected
  unless a new error atom needs registering.
- `test/erllama_nif_tests.erl` (or eunit equivalent) — add the
  guard tests here.

The existing pattern is: every llama.cpp entry point is wrapped in
an `erllama_safe_*` function in `erllama_safe.cpp` declared
`noexcept`, with a `try { ... } catch (...) { return SENTINEL; }`.
The NIF calls the safe wrapper and checks the sentinel before
continuing.

## Guards to add

### 1. `erllama_safe_n_ctx` / `erllama_safe_n_batch` accessors

Add to `c_src/erllama_safe.cpp`:

```cpp
uint32_t erllama_safe_n_ctx(const struct llama_context *c) noexcept {
    try { return llama_n_ctx(c); } catch (...) { return 0; }
}
uint32_t erllama_safe_n_batch(const struct llama_context *c) noexcept {
    try { return llama_n_batch(c); } catch (...) { return 0; }
}
```

Add the matching `extern` declarations in `erllama_nif.c` alongside
the existing `erllama_safe_vocab_n_tokens` block.

### 2. Guard `nif_prefill`

After the vocab-range loop (around `erllama_nif.c:1057-1063`),
before `llama_batch_get_one`, add:

```c
uint32_t n_ctx = erllama_safe_n_ctx(c->ctx);
uint32_t n_batch = erllama_safe_n_batch(c->ctx);
if (n_ctx == 0 || n_batch == 0) {
    pthread_mutex_unlock(&c->mu);
    enif_free(tokens);
    return enif_make_tuple2(env, atom_error, atom_exception);
}
if ((uint32_t) n >= n_ctx) {
    pthread_mutex_unlock(&c->mu);
    enif_free(tokens);
    return enif_make_tuple2(env, atom_error, atom_context_overflow);
}
if ((uint32_t) n > n_batch) {
    pthread_mutex_unlock(&c->mu);
    enif_free(tokens);
    return enif_make_tuple2(env, atom_error, atom_batch_overflow);
}
```

Register the two new atoms in the init block alongside
`atom_invalid_token`:
- `atom_context_overflow` — emitted when prompt tokens would
  exceed n_ctx.
- `atom_batch_overflow` — emitted when prompt tokens exceed
  n_batch in a single call.

### 3. Guard `nif_apply_chat_template`

Walk the messages array argv[1] and verify each `content` is a
binary. Return `{error, invalid_content}` (new atom) rather than
letting `enif_make_badarg` reach an Erlang-level `badarg`
exception across the dirty scheduler boundary. The downstream
server now flattens blocks before calling, but the NIF should
defend itself.

### 4. Guard `llama_load_model_from_file` aborts

The existing `set_abort_callback` hook routes llama.cpp aborts
somewhere — wire it to a `longjmp`-or-flag pattern so
`erllama_safe_model_load_from_file` can return NULL + sentinel
instead of letting `abort()` reach the OS. The NIF then returns
`{error, malformed_gguf}` (new atom). If a `longjmp` jacket is
unsafe because llama.cpp owns allocations at the abort point,
document that and at least catch a `bool` "model load aborted"
flag the safe wrapper polls after the call.

### 5. NULL-context defensive in every NIF that calls `c->ctx`

`nif_decode_one`, `nif_kv_pack`, `nif_kv_unpack`, `nif_kv_seq_rm`,
`nif_apply_chat_template`, `nif_embed` — each one already does
`if (!c->ctx) return atom_released`. Verify, add where missing,
and make sure the lock is held during the check.

## Patterns to reuse

- `atom_exception` for "C++ exception caught by safe wrapper" —
  already defined.
- `atom_released` for post-`free_context` calls — already defined.
- `atom_invalid_token` for vocab-range failures — already defined;
  mirror its registration in `init`/`reload` for the new atoms.
- `pthread_mutex_lock(&c->mu)` / `unlock` discipline around every
  `c->ctx` access.

Do NOT add `setjmp`/`longjmp` around `llama_decode` itself —
llama.cpp allocates inside and a longjmp would leak. Stick to
pre-call bounds checks.

## Tests

Add to the existing NIF test suite (eunit). Each case should use a
stub context loaded with the smallest possible model (or the test
fixture `LLAMA_TEST_MODEL` if set) and assert the new error
tuples:

```erlang
prefill_returns_context_overflow_when_prompt_too_long_test() ->
    {ok, Ctx} = test_load_small_model([{n_ctx, 64}]),
    Tokens = lists:seq(1, 100),       % 100 > 64
    ?assertEqual({error, context_overflow},
                 erllama_nif:prefill(Ctx, Tokens)).

prefill_returns_batch_overflow_when_prompt_exceeds_n_batch_test() ->
    {ok, Ctx} = test_load_small_model([{n_ctx, 4096}, {n_batch, 32}]),
    Tokens = lists:seq(1, 64),        % 64 > 32
    ?assertEqual({error, batch_overflow},
                 erllama_nif:prefill(Ctx, Tokens)).

apply_chat_template_rejects_non_binary_content_test() ->
    {ok, Model} = test_load_small_model([]),
    Req = #{messages => [#{role => <<"user">>,
                           content => [#{<<"text">> => <<"hi">>}]}]},
    ?assertEqual({error, invalid_content},
                 erllama_nif:apply_chat_template(Model, Req)).
```

Plus property-based fuzzing (PropEr is already in the deps): random
integer prompts of length 1..2*n_ctx should never crash the BEAM.
Just `?assertNotEqual` on a process-down message.

## Verification

```bash
rebar3 fmt --check
rebar3 compile      # warnings_as_errors must stay clean
rebar3 eunit
rebar3 proper       # the new fuzz case lives here
rebar3 ct           # full suite
rebar3 lint
rebar3 dialyzer
rebar3 xref

# Real-model smoke (only if LLAMA_TEST_MODEL is set):
LLAMA_TEST_MODEL=/path/to/tinyllama.gguf rebar3 ct \
  --suite=test/erllama_real_model_SUITE
```

Then in a shell:

```erlang
1> {ok, _} = application:ensure_all_started(erllama).
2> {ok, M} = erllama:load_model(<<"t">>,
2>     #{model_path => "...", context_size => 64, ...}).
3> erllama:tokenize(M, binary:copy(<<"x ">>, 200)).
%% expected: {ok, [...200 tokens...]}
4> erllama:complete(M, binary:copy(<<"x ">>, 200), #{}).
%% expected: {error, context_overflow}  -- NOT a BEAM crash.
```

## Out of scope

- Subprocess isolation (Ollama-style runner). The downstream
  evaluated it and chose not to: it costs the zero-copy token
  streaming, the OTP cancel-on-disconnect cascade, and the
  in-process KV cache that's central to erllama's design.
  Defensive input validation in the NIF is the chosen path.
- Streaming partial-prefill (chunked prompt > n_batch handled by
  splitting into batches automatically). Future work; today
  refusing oversized prompts is the right default.

## Constraints

- Keep the NIF on dirty CPU schedulers
  (`ERL_NIF_DIRTY_JOB_CPU_BOUND`) — do not move work onto the
  regular schedulers.
- Lock discipline: `c->mu` held for the full window between
  checking `c->ctx` and using it; safe wrappers can be called
  outside the lock if they don't touch `c->ctx`.
- No new third-party deps. Just llama.cpp + the existing safe.cpp
  jacket.
- Project conventions per `AGENTS.md`: no comments restating what
  the code does; only annotate non-obvious *why* (a hidden
  constraint, an invariant, a workaround).
