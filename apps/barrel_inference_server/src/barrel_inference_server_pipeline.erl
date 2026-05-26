%%% Per-request slow-phase worker for the chat / messages handlers.
%%%
%%% The handler runs the FAST phase (decode JSON, translate, resolve
%%% model, validate) inline in init/2. Anything that can block goes
%%% in this worker so the handler can sit in cowboy_loop and observe
%%% client disconnects promptly.
%%%
%%% Responsibilities, in order:
%%%
%%%   1. ensure_loaded(ModelId) via barrel_inference_server_config (which in
%%%      turn dispatches to a per-model loader; never blocks the
%%%      config server itself).
%%%   2. Tokenise the request:
%%%      - chat / messages: barrel_inference:apply_chat_template/2.
%%%      - legacy completions: barrel_inference:tokenize/2 on the raw prompt.
%%%   3. Build a GBNF grammar from the tools array
%%%      (barrel_inference_server_grammar:from_tools/2). Empty grammar means
%%%      no constraint, which the gen_statem treats as a no-op.
%%%   4. Acquire a queue slot via barrel_inference_server_queue:acquire/2.
%%%   5. Call barrel_inference:infer/4 with the OWNING handler's pid as
%%%      CallerPid. Tokens flow directly to the handler, never
%%%      through the worker.
%%%
%%% Progress messages back to the handler:
%%%
%%%   {pipeline, loaded}                    optional
%%%   {pipeline, templated, Tokens}         optional
%%%   {pipeline, queued}                    optional
%%%   {pipeline, admitted, InferRef, Slot}  required success
%%%   {pipeline, error, HttpStatus, Reason} required failure
%%%
%%% The worker is linked to the handler. If the handler dies (client
%%% disconnect), the link kills the worker which then runs its own
%%% cleanup (release the slot if held; cancel a started infer).

-module(barrel_inference_server_pipeline).

-include("barrel_inference_server.hrl").

%% Public ETS memo for the static-prefix head render, owned by
%% barrel_inference_server_config (created in its init/1).
-define(PREFIX_HEAD_TBL, barrel_inference_server_prefix_head).

-export([start_link/2, abort/1]).
%% Exported for unit tests (pure).
-export([build_params/1]).
%% Exported for unit tests (grammar-skip decision; step_grammar/1 is private).
-export([build_grammar/1]).
%% Exported for unit tests (pure context-fitting math).
-export([prompt_budget/2, keep_tail/2]).
%% Exported for unit tests (timeout + worker-kill behavior).
-export([call_engine/3]).

-record(work, {
    handler :: pid(),
    request :: #barrel_inference_request{},
    %% State filled in as we progress.
    tokens :: [non_neg_integer()] | undefined,
    %% When set, this turn extends a prior pinned session whose
    %% committed token-id list is on file and is a true prefix of the
    %% freshly rendered prompt. `continuation' is the new tail (tokens
    %% after that prefix); `infer/4' is replaced with
    %% `barrel_inference:continue/3' on this turn, passing `expect_committed'
    %% so the engine re-validates the splice. Unset on the first turn
    %% of a session, after a `no_session' / `transcript_mismatch'
    %% fallback, when there is no session_state entry, or when the
    %% stored committed tokens are not a prefix of the new render.
    continuation :: [non_neg_integer()] | undefined,
    %% The stored committed token-id list this continuation extends;
    %% forwarded to `barrel_inference:continue/3' as `expect_committed'.
    expect_committed :: [non_neg_integer()] | undefined,
    %% Verified end-of-tools token offset for the static-prefix
    %% checkpoint (see compute_prefix_boundary/2). Forwarded to the
    %% engine as `Params.prefix_checkpoint_len'. `undefined' when the
    %% request has no tools, the head render is unavailable, or the
    %% boundary is degenerate.
    prefix_checkpoint_len :: non_neg_integer() | undefined,
    slot :: barrel_inference_server_queue:slot() | undefined,
    infer_ref :: reference() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link(pid(), #barrel_inference_request{}) -> {pid(), reference()}.
start_link(Handler, Request) ->
    Pid = spawn_link(fun() -> run(#work{handler = Handler, request = Request}) end),
    Mon = erlang:monitor(process, Pid),
    {Pid, Mon}.

%% Ask the worker to abort. Best-effort: if the worker has already
%% admitted, it relies on the handler's terminate/3 to release the
%% slot and cancel the ref.
-spec abort(pid()) -> ok.
abort(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> exit(Pid, abort);
        false -> ok
    end,
    ok.

%%====================================================================
%% Driver
%%====================================================================

run(W) ->
    Step = step_load(W),
    case Step of
        {ok, W1} -> run_template(W1);
        {error, Status, Why} -> fail(W, Status, Why)
    end.

run_template(W) ->
    case step_template(W) of
        {ok, W1} -> run_grammar(W1);
        {error, Status, Why} -> fail(W, Status, Why)
    end.

run_grammar(W) ->
    case step_grammar(W) of
        {ok, W1} -> run_queue(W1);
        {error, Status, Why} -> fail(W, Status, Why)
    end.

run_queue(W) ->
    case step_queue(W) of
        {ok, W1} -> run_infer(W1);
        {error, Status, Why} -> fail(W, Status, Why)
    end.

run_infer(W) ->
    case step_infer(W) of
        {ok, W1} -> succeed(W1);
        {error, Status, Why} -> release_and_fail(W, Status, Why)
    end.

succeed(W) ->
    W#work.handler ! {pipeline, admitted, W#work.infer_ref, W#work.slot},
    ok.

fail(W, Status, Reason) ->
    W#work.handler ! {pipeline, error, Status, Reason},
    ok.

release_and_fail(W = #work{slot = Slot}, Status, Reason) when is_reference(Slot) ->
    barrel_inference_server_queue:release(model_id(W), Slot),
    fail(W, Status, Reason).

%%====================================================================
%% Steps
%%====================================================================

step_load(W) ->
    ModelId = model_id(W),
    case barrel_inference_server_config:ensure_loaded_async(ModelId, self(), load_deadline()) of
        ok ->
            wait_for_load(W, ModelId, load_deadline());
        {error, Reason} ->
            {error, code_for(Reason), Reason}
    end.

%% Loop on {barrel_inference_load_progress, _} ticks (forwarded to the handler
%% as {pipeline, loading, _}) until either the done message arrives
%% or the request deadline fires. Reusing the per-request deadline
%% keeps the existing load_timeout semantics.
wait_for_load(W, ModelId, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            {error, 504, model_load_timeout};
        false ->
            receive
                {barrel_inference_load_progress, ModelId} ->
                    W#work.handler ! {pipeline, loading, ModelId},
                    wait_for_load(W, ModelId, Deadline);
                {barrel_inference_load_done, ModelId, ok} ->
                    W#work.handler ! {pipeline, loaded},
                    {ok, W};
                {barrel_inference_load_done, ModelId, {error, Reason}} ->
                    {error, code_for(Reason), Reason}
            after max(0, Deadline - Now) ->
                {error, 504, model_load_timeout}
            end
    end.

code_for(not_found) -> 404;
code_for(not_preloaded) -> 503;
code_for(not_loaded) -> 503;
code_for(load_failed) -> 503;
code_for(load_timeout) -> 504;
code_for(_) -> 500.

load_deadline() ->
    erlang:monotonic_time(millisecond) + barrel_inference_server_config:prefill_ms().

step_template(W) ->
    R = W#work.request,
    case R#barrel_inference_request.prompt of
        undefined ->
            apply_chat_template(W);
        Prompt when is_binary(Prompt) ->
            tokenise_raw(W, Prompt)
    end.

apply_chat_template(W) ->
    R = W#work.request,
    Messages = R#barrel_inference_request.messages,
    System = R#barrel_inference_request.system,
    Tools = R#barrel_inference_request.tools,
    %% Walk the message history before rendering so the exact-replay
    %% counters reflect what fraction of prior tool_use blocks land a
    %% hit in the replay map. Once barrel_inference exposes a verbatim-content
    %% escape on apply_chat_template/2 the FullBin will also splice
    %% into the rendered prompt here; today we ride the chat template's
    %% own JSON formatting (which is byte-stable across turns for
    %% well-aligned model families) and let cache_delta tell us how
    %% often that's enough.
    ok = note_tool_replay_lookups(model_id(W), Messages),
    apply_chat_template_with_truncate(W, System, Tools, Messages).

note_tool_replay_lookups(Model, Messages) ->
    lists:foreach(
        fun(Msg) -> walk_message_for_tool_use(Model, Msg) end,
        Messages
    ),
    ok.

walk_message_for_tool_use(Model, #{content := Blocks}) when is_list(Blocks) ->
    lists:foreach(
        fun(Block) -> note_tool_use_block(Model, Block) end,
        Blocks
    );
walk_message_for_tool_use(_Model, _) ->
    ok.

note_tool_use_block(Model, #{<<"type">> := <<"tool_use">>, <<"id">> := Id}) when
    is_binary(Id)
->
    case barrel_inference_server_tool_format:lookup(Model) of
        not_found ->
            barrel_inference_server_metrics:inc_tool_replay_lookup(Model, no_format);
        {ok, _Spec} ->
            case barrel_inference_server_tool_replay:get(Id) of
                {ok, _} ->
                    barrel_inference_server_metrics:inc_tool_replay_lookup(Model, hit);
                not_found ->
                    barrel_inference_server_metrics:inc_tool_replay_lookup(Model, miss)
            end
    end;
note_tool_use_block(_Model, _) ->
    ok.

%% Render the chat template; if the resulting token count would
%% overflow n_ctx, drop the oldest non-system message and retry.
%% Mirrors Ollama's `server/prompt.go` truncation strategy: preserve
%% system + the final (most recent) message, shave from the head.
%% Cap retries so a single oversized final turn fails cleanly with
%% 400 / `context_overflow' rather than looping. llama.cpp would
%% otherwise segfault when the prefill batch token count >= n_ctx.
%% Per Anthropic / OpenAI conventions, prompt-too-long is 400
%% `invalid_request_error', not 413 `request_too_large' (which is
%% reserved for raw byte size).
apply_chat_template_with_truncate(W, System, Tools, Messages) ->
    case render_template(W, System, Tools, Messages) of
        {ok, Tokens} ->
            case fits_context(W, length(Tokens)) of
                ok ->
                    accept_tokens(W, Tokens);
                {error, 503, _} = E ->
                    E;
                {overflow, Ctx} when length(Messages) =< 1 ->
                    {error, 400, {context_overflow, length(Tokens), Ctx}};
                {overflow, _Ctx} ->
                    apply_chat_template_with_truncate(
                        W, System, Tools, drop_oldest_non_system(Messages)
                    )
            end;
        {error, _, _} = E ->
            E
    end.

render_template(W, System0, Tools0, Messages) ->
    ModelId = model_id(W),
    %% On the native tool path, render the model's own tool block into the
    %% system prompt (with schemas) and stop passing `tools' to the NIF so
    %% it doesn't also append its prose list. Gating on native_turn/1 (not
    %% the model alone) guarantees Tools0 is a non-empty list and
    %% tool_choice = auto here. Same decision as build_grammar/1, so the
    %% skip and the render stay in lockstep.
    {System, Tools} = transform_native_tools(W, System0, Tools0),
    Req = #{messages => Messages, system => System, tools => Tools},
    Call = fun() -> barrel_inference:apply_chat_template(ModelId, Req) end,
    case call_engine_with_recovery(W, Call, apply_chat_template) of
        {ok, {ok, Tokens}} ->
            {ok, Tokens};
        {ok, {error, no_template}} ->
            {error, 501, no_chat_template};
        {ok, {error, not_supported}} ->
            {error, 501, chat_template_not_supported};
        {ok, {error, Reason}} ->
            {error, 400, Reason};
        {error, _, _} = E ->
            E
    end.

tokenise_raw(W, Prompt) ->
    ModelId = model_id(W),
    Call = fun() -> barrel_inference:tokenize(ModelId, Prompt) end,
    case call_engine_with_recovery(W, Call, tokenize) of
        {ok, {ok, Tokens}} ->
            case fits_context(W, length(Tokens)) of
                ok ->
                    accept_tokens(W, Tokens);
                {error, _, _} = E ->
                    E;
                {overflow, Budget} ->
                    %% Ollama-style: truncate the raw prompt to fit (keep
                    %% the most-recent tokens) rather than 400. The chat
                    %% path truncates by dropping oldest messages.
                    accept_tokens(W, keep_tail(Tokens, Budget))
            end;
        {ok, {error, Reason}} ->
            {error, 400, Reason};
        {error, _, _} = E ->
            E
    end.

keep_tail(Tokens, N) ->
    Len = length(Tokens),
    case Len > N of
        true -> lists:nthtail(Len - N, Tokens);
        false -> Tokens
    end.

%% Wrap a blocking engine call (gen_statem:call to barrel_inference_model,
%% which uses `infinity' internally) in a bounded timeout. If the
%% engine wedges inside the NIF (silent llama_decode failure, KV
%% corruption, ...), the caller would otherwise hang forever and
%% Claude Code's 5 min client cap would close the socket with no
%% status logged. With a bounded timeout the handler emits a clean
%% 504 `engine_unresponsive' in seconds and the connection is freed
%% for the next request. The worker process is left running because
%% killing the caller of an in-flight gen_statem:call doesn't abort
%% the engine's work; once the engine eventually responds, the
%% orphan exits naturally.
call_engine(Fun, ModelId, Op) ->
    Self = self(),
    Tag = make_ref(),
    Worker = spawn(fun() ->
        Result =
            try Fun() of
                R -> {ok, R}
            catch
                exit:{noproc, {barrel_inference_model, not_found, _}} ->
                    {error, 503, not_loaded};
                Class:Why:Stack ->
                    log_barrel_inference_crash(ModelId, Op, Class, Why, Stack),
                    {error, 500, model_crashed}
            end,
        Self ! {Tag, Result}
    end),
    receive
        {Tag, R} -> R
    after engine_call_timeout_ms() ->
        logger:warning(
            "barrel_inference_server: engine call timed out: model=~ts op=~p",
            [ModelId, Op]
        ),
        %% Don't leak the worker or its late reply. The engine-side work is
        %% aborted by the reset_session recovery path (call_engine_with_recovery).
        exit(Worker, kill),
        receive
            {Tag, _} -> ok
        after 0 -> ok
        end,
        {error, 504, engine_unresponsive}
    end.

engine_call_timeout_ms() ->
    application:get_env(barrel_inference_server, engine_call_timeout_ms, 30000).

%% On `engine_unresponsive' (the 504 from `call_engine/3`'s
%% bounded timeout), invoke the upstream `barrel_inference:reset_session/2'
%% recovery primitive (barrel_inference 0.7+) and retry the call once. Reset
%% drops the session's live KV cells and any in-flight `#req{}'
%% tagged to its seq, then returns the seq to the idle pool. Uses
%% a short 5 s `gen_statem:call` timeout upstream so it stays
%% reachable when the engine's hot path is wedged.
%%
%% If the retry's `do_infer' had `continuation' armed, the engine
%% has no session post-reset; `do_infer' falls through `no_session'
%% to a cold `infer/4', so the retry succeeds cold rather than
%% asserting on the now-evicted KV.
%%
%% When `reset_session/2' itself returns `{error, timeout}', the
%% engine's mailbox is unreachable - the model is genuinely dead
%% and the daemon needs a restart. We surface the original 504
%% with an explicit error log.
call_engine_with_recovery(W, Fun, Op) ->
    ModelId = model_id(W),
    case call_engine(Fun, ModelId, Op) of
        {error, 504, engine_unresponsive} ->
            try_reset_and_retry(W, Fun, Op);
        Other ->
            Other
    end.

try_reset_and_retry(W, Fun, Op) ->
    ModelId = model_id(W),
    R = W#work.request,
    case R#barrel_inference_request.session_id of
        undefined ->
            %% No sticky session to reset - the wedge is at cold
            %% admit (global context), not per-session KV. Escalate
            %% straight to unload.
            escalate_unload(ModelId, Op);
        SessionId ->
            case barrel_inference:reset_session(ModelId, SessionId) of
                {ok, Outcome} ->
                    logger:warning(
                        "barrel_inference_server: engine reset (~p), retrying: "
                        "model=~ts op=~p",
                        [Outcome, ModelId, Op]
                    ),
                    clear_session_state(W),
                    case call_engine(Fun, ModelId, Op) of
                        {error, 504, engine_unresponsive} ->
                            %% Per-session reset didn't unwedge it -
                            %% the wedge is at the global llama.cpp
                            %% context level, which reset_session
                            %% structurally can't reach. Escalate.
                            escalate_unload(ModelId, Op);
                        Other ->
                            Other
                    end;
                {error, timeout} ->
                    %% reset_session itself couldn't reach the
                    %% gen_statem mailbox. Unload is supervisor-level
                    %% so it lands anyway.
                    escalate_unload(ModelId, Op)
            end
    end.

%% Last-resort recovery for a wedge that per-session reset can't
%% clear (global llama.cpp context stuck at admit, or an unreachable
%% gen_statem mailbox). `barrel_inference:unload/1' goes through the model
%% supervisor's `terminate_child', not a gen_statem:call, so it
%% lands even when the engine is stuck in a dirty NIF. The next
%% request's `ensure_loaded' reloads a fresh context cold. We return
%% 503 `model_reloading' so the Anthropic surface remaps to 529 +
%% retry-after (SDKs back off) and OpenAI / Responses callers retry
%% against the reloaded model. Converts "wedge = dead daemon until
%% manual restart" into "wedge = one 503, then self-healed".
escalate_unload(ModelId, Op) ->
    logger:error(
        "barrel_inference_server: engine unrecoverable via reset; unloading "
        "model=~ts op=~p - next request reloads cold",
        [ModelId, Op]
    ),
    _ = barrel_inference:unload(ModelId),
    {error, 503, model_reloading}.

accept_tokens(W, Tokens) ->
    W1 = put_tokens(W, Tokens),
    W2 = maybe_arm_continuation(W1, Tokens),
    W3 = compute_prefix_boundary(W2, Tokens),
    W#work.handler ! {pipeline, templated, Tokens},
    {ok, W3}.

%% Verify the static-prefix (end-of-tools) boundary for the static
%% system+tools head and stamp its token offset on the work record so
%% the engine writes + pins an `agent_prefix` checkpoint there. Only
%% when the request carries tools (the bulk of the static head). The
%% boundary is the longest common token prefix of the head-only render
%% (empty messages) and the full render: the two agree exactly up to
%% where the messages begin, so no template-specific marker stripping
%% is needed and the result is always a true prefix of `Tokens`.
compute_prefix_boundary(W, Tokens) ->
    R = W#work.request,
    case R#barrel_inference_request.tools of
        Tools when is_list(Tools), Tools =/= [] ->
            case head_tokens(W, R#barrel_inference_request.system, Tools) of
                {ok, HeadTokens} ->
                    N = lcp_len(HeadTokens, Tokens),
                    case N > 0 andalso N < length(Tokens) of
                        true -> W#work{prefix_checkpoint_len = N};
                        false -> W
                    end;
                none ->
                    W
            end;
        _ ->
            W
    end.

%% Head-only render of the transformed system+tools (same native-tool
%% fold render_template/4 applies), memoized per transformed-head
%% identity in the public ETS table. Returns `none` on any render
%% failure (skip the boundary; never guess).
head_tokens(W, System0, Tools0) ->
    ModelId = model_id(W),
    {System2, Tools2} = transform_native_tools(W, System0, Tools0),
    MemoKey = crypto:hash(sha256, term_to_binary({ModelId, System2, Tools2})),
    case ets:lookup(?PREFIX_HEAD_TBL, MemoKey) of
        [{_, HeadTokens}] ->
            {ok, HeadTokens};
        [] ->
            Req = #{messages => [], system => System2, tools => Tools2},
            Call = fun() -> barrel_inference:apply_chat_template(ModelId, Req) end,
            case call_engine_with_recovery(W, Call, apply_chat_template) of
                {ok, {ok, HeadTokens}} ->
                    ets:insert(?PREFIX_HEAD_TBL, {MemoKey, HeadTokens}),
                    {ok, HeadTokens};
                _ ->
                    none
            end
    end.

%% On the native-tool path, fold the model's own tool block (with
%% schemas) into the system prompt and stop passing `tools' to the NIF
%% so it doesn't also append its prose list. Shared by render_template/4
%% and head_tokens/3 so the full render and the head render transform
%% identically.
transform_native_tools(W, System0, Tools0) ->
    case barrel_inference_server_tool_format:native_turn(W#work.request) of
        {ok, Mod} ->
            {barrel_inference_server_tool_format:render(Mod, Tools0, System0), undefined};
        none ->
            {System0, Tools0}
    end.

%% Longest common prefix length of two token lists (tail-recursive;
%% prompts can be tens of thousands of tokens).
lcp_len(As, Bs) -> lcp_len(As, Bs, 0).

lcp_len([X | As], [X | Bs], N) -> lcp_len(As, Bs, N + 1);
lcp_len(_, _, N) -> N.

%% When the request's session has a prior committed token-id list on
%% file AND that list is a strict prefix of the freshly rendered
%% prompt, this turn is a byte-exact continuation: slice the tokens
%% after the prefix and route through `barrel_inference:continue/3' (passing
%% `expect_committed') instead of `infer/4'. Returns the work record
%% annotated with the suffix + expected prefix on success; leaves it
%% untouched (first turn / no session state / the new render does not
%% extend the stored prefix - e.g. the chat template re-rendered prior
%% turns differently) so step_infer falls through to a correct, full
%% `infer/4' instead of producing garbage.
maybe_arm_continuation(W, Tokens) ->
    R = W#work.request,
    case R#barrel_inference_request.session_id of
        undefined ->
            W;
        SessionId ->
            case
                barrel_inference_server_session_state:get(
                    R#barrel_inference_request.model_id, SessionId
                )
            of
                {ok, Committed} when
                    is_list(Committed),
                    Committed =/= [],
                    length(Committed) < length(Tokens)
                ->
                    case lists:prefix(Committed, Tokens) of
                        true ->
                            Suffix = lists:nthtail(length(Committed), Tokens),
                            W#work{continuation = Suffix, expect_committed = Committed};
                        false ->
                            W
                    end;
                _ ->
                    W
            end
    end.

%% Returns `ok` if the prompt fits, `{overflow, Ctx}` if it doesn't,
%% or `{error, 503, not_loaded}` if the model has gone away between
%% load and template. Reading context_size via model_info is a single
%% gen_statem:call into the model itself; cheap enough to call once
%% per template attempt.
fits_context(W, NToks) ->
    case prompt_budget(W) of
        undefined -> {error, 503, not_loaded};
        Budget when NToks >= Budget -> {overflow, Budget};
        _Budget -> ok
    end.

%% Per-request effective context: the loaded context, optionally capped
%% DOWN by the request's `num_ctx` (`context_cap`). A request can only
%% shrink the window - the KV cache is sized at load - so a larger
%% `num_ctx` is clamped to the loaded context (no reload).
effective_context(W) ->
    case context_size(model_id(W)) of
        undefined ->
            undefined;
        Loaded ->
            case (W#work.request)#barrel_inference_request.context_cap of
                N when is_integer(N), N > 0 -> min(N, Loaded);
                _ -> Loaded
            end
    end.

%% Token budget for the PROMPT, reserving room for the requested
%% generation so prompt + generation <= effective context (llama.cpp
%% decode-fails when the two together exceed n_ctx). Reserve up to the
%% requested `max_tokens`, capped at half the window so neither prompt nor
%% generation is starved; at least 1 token each. `clamp_response_tokens/2`
%% is the matching hard guarantee on the generation side.
prompt_budget(W) ->
    case effective_context(W) of
        undefined ->
            undefined;
        EffCtx ->
            prompt_budget(EffCtx, (W#work.request)#barrel_inference_request.max_tokens)
    end.

%% Pure: prompt token budget given the effective context and the
%% requested generation (`max_tokens`). Reserve up to `MaxTokens`, capped
%% at half the window so neither prompt nor generation is starved; >= 1
%% each.
prompt_budget(EffCtx, MaxTokens) ->
    Reserve = max(1, min(MaxTokens, EffCtx div 2)),
    max(1, EffCtx - Reserve).

%% Drop the OLDEST non-system message. System messages anchor the
%% conversation's persona / tool contract and Ollama preserves them
%% even after truncation. The very last message is always retained;
%% if it alone overflows, the caller is told (413).
drop_oldest_non_system([]) ->
    [];
drop_oldest_non_system([Last]) ->
    [Last];
drop_oldest_non_system([#{role := <<"system">>} = First | Rest]) ->
    [First | drop_oldest_non_system(Rest)];
drop_oldest_non_system([_ | Rest]) ->
    Rest.

context_size(ModelId) ->
    try barrel_inference:model_info(ModelId) of
        #{context_size := N} when is_integer(N), N > 0 -> N;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

step_grammar(W) ->
    R = W#work.request,
    case build_grammar(R) of
        {ok, Bin} ->
            W1 = W#work{request = R#barrel_inference_request{grammar = nullable_bin(Bin)}},
            {ok, W1};
        {error, Reason} ->
            {error, 400, Reason}
    end.

%% Decide the grammar source for a request. On the native free-decode
%% tool path (marker model + native renderer + tool_choice = auto) emit
%% an empty grammar so the model decodes freely and the marker capture
%% path (barrel_inference_tool_call_end) collects the calls - the GBNF
%% grammar is ~40x slower per token and pure overhead there. Otherwise:
%% a non-empty tools array builds the tool grammar, else the
%% response_format / format directive drives it. nullable_bin/1 maps the
%% empty grammar to `undefined' (no constraint).
build_grammar(R) ->
    case barrel_inference_server_tool_format:native_turn(R) of
        {ok, _Format} ->
            {ok, <<>>};
        none ->
            case has_tools(R) of
                true ->
                    barrel_inference_server_grammar:from_tools(
                        R#barrel_inference_request.tools, R#barrel_inference_request.tool_choice
                    );
                false ->
                    barrel_inference_server_grammar:from_response_format(
                        R#barrel_inference_request.response_format
                    )
            end
    end.

has_tools(#barrel_inference_request{tools = undefined}) -> false;
has_tools(#barrel_inference_request{tools = []}) -> false;
has_tools(#barrel_inference_request{tools = [_ | _]}) -> true.

%% Cap the generation budget to the room left after the (already
%% truncated) prompt, so prompt + generation never exceed the effective
%% context. The hard guarantee behind prompt_budget/1; applied with the
%% rendered prompt token count known (W#work.tokens).
clamp_response_tokens(W, Params) ->
    case effective_context(W) of
        undefined ->
            Params;
        EffCtx ->
            Room = max(1, EffCtx - length(W#work.tokens)),
            case maps:get(response_tokens, Params, undefined) of
                N when is_integer(N), N > Room -> Params#{response_tokens => Room};
                _ -> Params
            end
    end.

step_queue(W) ->
    Model = model_id(W),
    Timeout = queue_timeout(Model),
    case barrel_inference_server_queue:acquire(Model, Timeout) of
        {ok, Slot} ->
            W#work.handler ! {pipeline, queued},
            {ok, W#work{slot = Slot}};
        {error, pool_exhausted} ->
            barrel_inference_server_metrics:inc_pool_exhausted(Model),
            {error, 429, pool_exhausted};
        {error, queue_timeout} ->
            {error, 504, queue_timeout};
        {error, Reason} ->
            {error, 500, Reason}
    end.

step_infer(W) ->
    Params0 = maybe_put(
        build_params(W#work.request), prefix_checkpoint_len, W#work.prefix_checkpoint_len
    ),
    Params = clamp_response_tokens(W, Params0),
    Call = fun() -> do_infer(W, Params) end,
    %% do_infer picks infer/4 vs continue/3 from W#work.continuation; label
    %% the admission metric the same way so the two paths are distinguishable.
    Op =
        case W#work.continuation of
            undefined -> infer;
            _ -> continue
        end,
    T0 = erlang:monotonic_time(millisecond),
    Result = call_engine_with_recovery(W, Call, Op),
    observe_admit_latency(W, Op, T0),
    case Result of
        {ok, {ok, Ref}} ->
            {ok, W#work{infer_ref = Ref}};
        {ok, {error, busy}} ->
            barrel_inference_server_metrics:inc_pool_exhausted(model_id(W)),
            {error, 429, busy};
        %% barrel_inference 0.5.0: two concurrent admits on the same session_id
        %% are out of scope - the second returns sticky_busy. Map to a
        %% retryable 503; the Anthropic handler further remaps 503 to
        %% 529 with a retry-after header that SDKs honour as the next
        %% backoff delay.
        {ok, {error, sticky_busy}} ->
            {error, 503, sticky_busy};
        %% barrel_inference 0.8.0 `on_full => error': the seq pool is full (no
        %% free seq). Retryable, same surface mapping as sticky_busy
        %% (Anthropic remaps 503 -> 529 + retry-after).
        {ok, {error, seq_capacity}} ->
            barrel_inference_server_metrics:inc_pool_exhausted(model_id(W)),
            {error, 503, seq_capacity};
        {ok, {error, Reason}} ->
            {error, 500, Reason};
        {error, _, _} = E ->
            E
    end.

%% Record admission latency (grammar compile + prefill) per infer/continue
%% op, in seconds (house convention), via the metrics module. A slow admit
%% is logged so a too-low engine_call_timeout_ms is visible in the logs.
observe_admit_latency(W, Op, T0) ->
    Ms = erlang:monotonic_time(millisecond) - T0,
    barrel_inference_server_metrics:observe_engine_admit(model_id(W), Op, Ms / 1000),
    case Ms >= admit_warn_ms() of
        true ->
            logger:warning(
                "barrel_inference_server: slow engine admit: model=~ts op=~p ~Bms",
                [model_id(W), Op, Ms]
            );
        false ->
            ok
    end.

admit_warn_ms() ->
    application:get_env(barrel_inference_server, engine_admit_warn_ms, 10000).

%% Try `continue/3' when the work record carries a suffix; fall
%% through to a full `infer/4' on `no_session' (engine has no
%% session entry for this id - TTL evict, server restart wiped
%% our cache but engine didn't match, etc.). Other errors bubble
%% up unchanged.
do_infer(#work{continuation = undefined} = W, Params) ->
    barrel_inference:infer(model_id(W), W#work.tokens, Params, W#work.handler);
do_infer(W, Params) ->
    R = W#work.request,
    ContOpts = maps:merge(Params, #{
        session_id => R#barrel_inference_request.session_id,
        caller_pid => W#work.handler,
        expect_committed => W#work.expect_committed
    }),
    case barrel_inference:continue(model_id(W), W#work.continuation, ContOpts) of
        %% Engine has no session entry (TTL evict, restart, prior
        %% cancel-mid-flight) or our committed list disagrees with the
        %% engine's stored context (transcript_mismatch). Either way the
        %% slice is unsafe: drop the stale state and re-admit cold with
        %% the full token list.
        {error, no_session} ->
            clear_session_state(W),
            barrel_inference:infer(model_id(W), W#work.tokens, Params, W#work.handler);
        {error, {transcript_mismatch, _}} ->
            clear_session_state(W),
            barrel_inference:infer(model_id(W), W#work.tokens, Params, W#work.handler);
        Other ->
            Other
    end.

clear_session_state(W) ->
    R = W#work.request,
    case R#barrel_inference_request.session_id of
        undefined ->
            ok;
        SessionId ->
            barrel_inference_server_session_state:delete(
                R#barrel_inference_request.model_id, SessionId
            )
    end.

%% Convert crashes coming back from barrel_inference (gen_statem `call` exits,
%% function clauses inside the model gen_statem, etc.) into a clean
%% error tuple. The request process never dies; the supervisor
%% restart-storm that follows a crashing model still happens upstream
%% but the client sees a JSON 500 instead of a torn HTTP connection.
log_barrel_inference_crash(ModelId, Step, Class, Why, Stack) ->
    logger:error(
        "barrel_inference crash in ~p for ~ts: ~p:~p~n~p",
        [Step, ModelId, Class, Why, Stack]
    ),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

model_id(#work{request = #barrel_inference_request{model_id = Id}}) -> Id.

put_tokens(W, Tokens) ->
    W#work{tokens = Tokens}.

nullable_bin(<<>>) -> undefined;
nullable_bin(B) -> B.

queue_timeout(Model) ->
    case barrel_inference_server_config:pool_policy_for(Model) of
        immediate_429 ->
            0;
        {queue, #{timeout_ms := T}} ->
            T
    end.

build_params(R) ->
    Base = #{
        response_tokens => R#barrel_inference_request.max_tokens,
        temperature => R#barrel_inference_request.temperature,
        top_p => R#barrel_inference_request.top_p,
        top_k => R#barrel_inference_request.top_k,
        min_p => R#barrel_inference_request.min_p,
        %% barrel_inference 0.3.0 renamed the placeholder `stop` to
        %% `stop_sequences` and wired it up: generation halts on the
        %% first match in the accumulated detokenised output and the
        %% matched binary comes back in Stats.
        stop_sequences => R#barrel_inference_request.stop,
        thinking => R#barrel_inference_request.thinking
    },
    Maybe1 = maybe_put(Base, seed, R#barrel_inference_request.seed),
    Maybe2 = maybe_put(Maybe1, grammar, R#barrel_inference_request.grammar),
    %% barrel_inference 0.4.0 accepts thinking_budget_tokens as a caller-side cap
    %% on extended-thinking length. Forward Anthropic's
    %% thinking.budget_tokens through when set and positive; the engine
    %% treats absent / non-positive as "no cap".
    Maybe3 = maybe_put(Maybe2, thinking_budget_tokens, R#barrel_inference_request.thinking_budget),
    %% barrel_inference 0.5.0 pins the underlying seq_id to whatever session_id
    %% Params carries. The next turn on the same id truncates-and-
    %% prefills in place on the live KV cells instead of warm-restoring
    %% from disk. Cancel is async (next decode tick observes it) so a
    %% retry with the same session_id during that window gets
    %% `{error, sticky_busy}` -> 503; SDKs honour Retry-After.
    Maybe4 = maybe_put(Maybe3, session_id, R#barrel_inference_request.session_id),
    %% barrel_inference 0.8.0: `on_full => error' fails an admission fast with
    %% `{error, seq_capacity}' when no seq is free instead of blocking
    %% (the engine default). Under sticky pinning the seq pool can be
    %% full while our queue still has a slot, so fail-fast + retry beats
    %% blocking until a request timeout fires. Opt-in via the
    %% `admission_on_full' app env; absent leaves the engine on `block'.
    maybe_put(Maybe4, on_full, admission_on_full()).

admission_on_full() ->
    case application:get_env(barrel_inference_server, admission_on_full, undefined) of
        error -> error;
        _ -> undefined
    end.

maybe_put(Map, _Key, undefined) -> Map;
maybe_put(Map, Key, Value) -> Map#{Key => Value}.
