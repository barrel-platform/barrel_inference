%%% Per-request slow-phase worker for the chat / messages handlers.
%%%
%%% The handler runs the FAST phase (decode JSON, translate, resolve
%%% model, validate) inline in init/2. Anything that can block goes
%%% in this worker so the handler can sit in cowboy_loop and observe
%%% client disconnects promptly.
%%%
%%% Responsibilities, in order:
%%%
%%%   1. ensure_loaded(ModelId) via erllama_server_config (which in
%%%      turn dispatches to a per-model loader; never blocks the
%%%      config server itself).
%%%   2. Tokenise the request:
%%%      - chat / messages: erllama:apply_chat_template/2.
%%%      - legacy completions: erllama:tokenize/2 on the raw prompt.
%%%   3. Build a GBNF grammar from the tools array
%%%      (erllama_server_grammar:from_tools/2). Empty grammar means
%%%      no constraint, which the gen_statem treats as a no-op.
%%%   4. Acquire a queue slot via erllama_server_queue:acquire/2.
%%%   5. Call erllama:infer/4 with the OWNING handler's pid as
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

-module(erllama_server_pipeline).

-include("erllama_server.hrl").

-export([start_link/2, abort/1]).

-record(work, {
    handler :: pid(),
    request :: #erllama_request{},
    %% State filled in as we progress.
    tokens :: [non_neg_integer()] | undefined,
    slot :: erllama_server_queue:slot() | undefined,
    infer_ref :: reference() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link(pid(), #erllama_request{}) -> {pid(), reference()}.
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
    erllama_server_queue:release(model_id(W), Slot),
    fail(W, Status, Reason).

%%====================================================================
%% Steps
%%====================================================================

step_load(W) ->
    ModelId = model_id(W),
    case erllama_server_config:ensure_loaded_async(ModelId, self(), load_deadline()) of
        ok ->
            wait_for_load(W, ModelId, load_deadline());
        {error, Reason} ->
            {error, code_for(Reason), Reason}
    end.

%% Loop on {erllama_load_progress, _} ticks (forwarded to the handler
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
                {erllama_load_progress, ModelId} ->
                    W#work.handler ! {pipeline, loading, ModelId},
                    wait_for_load(W, ModelId, Deadline);
                {erllama_load_done, ModelId, ok} ->
                    W#work.handler ! {pipeline, loaded},
                    {ok, W};
                {erllama_load_done, ModelId, {error, Reason}} ->
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
    erlang:monotonic_time(millisecond) + erllama_server_config:prefill_ms().

step_template(W) ->
    R = W#work.request,
    case R#erllama_request.prompt of
        undefined ->
            apply_chat_template(W);
        Prompt when is_binary(Prompt) ->
            tokenise_raw(W, Prompt)
    end.

apply_chat_template(W) ->
    R = W#work.request,
    Req = #{
        messages => R#erllama_request.messages,
        system => R#erllama_request.system,
        tools => R#erllama_request.tools
    },
    try erllama:apply_chat_template(model_id(W), Req) of
        {ok, Tokens} ->
            check_token_budget(W, Tokens);
        {error, no_template} ->
            {error, 501, no_chat_template};
        {error, not_supported} ->
            {error, 501, chat_template_not_supported};
        {error, Reason} ->
            {error, 400, Reason}
    catch
        exit:{noproc, {erllama_model, not_found, _}} ->
            {error, 503, not_loaded};
        Class:Why:Stack ->
            log_erllama_crash(model_id(W), apply_chat_template, Class, Why, Stack),
            {error, 500, model_crashed}
    end.

tokenise_raw(W, Prompt) ->
    try erllama:tokenize(model_id(W), Prompt) of
        {ok, Tokens} ->
            check_token_budget(W, Tokens);
        {error, Reason} ->
            {error, 400, Reason}
    catch
        exit:{noproc, {erllama_model, not_found, _}} ->
            {error, 503, not_loaded};
        Class:Why:Stack ->
            log_erllama_crash(model_id(W), tokenize, Class, Why, Stack),
            {error, 500, model_crashed}
    end.

%% Guard against oversized prompts. llama.cpp segfaults if the input
%% token count >= n_ctx — the KV cache can't fit the prompt and the
%% decode dereferences off the end of the slab. We need at least one
%% token of headroom for generation, so the check is `NToks >= Ctx`.
%% Generation truncation past max_tokens is handled by the sampler;
%% it's not a server-side error.
check_token_budget(W, Tokens) ->
    NToks = length(Tokens),
    case context_size(model_id(W)) of
        undefined ->
            %% Model went away between load and template; surface
            %% as 503 rather than risk a NIF segfault on the next call.
            {error, 503, not_loaded};
        Ctx when NToks >= Ctx ->
            {error, 413, #{
                error => context_overflow,
                prompt_tokens => NToks,
                context_size => Ctx
            }};
        _Ctx ->
            W1 = put_tokens(W, Tokens),
            W#work.handler ! {pipeline, templated, Tokens},
            {ok, W1}
    end.

context_size(ModelId) ->
    try erllama:model_info(ModelId) of
        #{context_size := N} when is_integer(N), N > 0 -> N;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

step_grammar(W) ->
    R = W#work.request,
    %% Tools-driven grammar wins if a non-empty tools array is set.
    %% Otherwise honour the response_format / format directive.
    Build =
        case has_tools(R) of
            true ->
                erllama_server_grammar:from_tools(
                    R#erllama_request.tools, R#erllama_request.tool_choice
                );
            false ->
                erllama_server_grammar:from_response_format(R#erllama_request.response_format)
        end,
    case Build of
        {ok, Bin} ->
            W1 = W#work{request = R#erllama_request{grammar = nullable_bin(Bin)}},
            {ok, W1};
        {error, Reason} ->
            {error, 400, Reason}
    end.

has_tools(#erllama_request{tools = undefined}) -> false;
has_tools(#erllama_request{tools = []}) -> false;
has_tools(#erllama_request{tools = [_ | _]}) -> true.

step_queue(W) ->
    Model = model_id(W),
    Timeout = queue_timeout(Model),
    case erllama_server_queue:acquire(Model, Timeout) of
        {ok, Slot} ->
            W#work.handler ! {pipeline, queued},
            {ok, W#work{slot = Slot}};
        {error, pool_exhausted} ->
            erllama_server_metrics:inc_pool_exhausted(Model),
            {error, 429, pool_exhausted};
        {error, queue_timeout} ->
            {error, 504, queue_timeout};
        {error, Reason} ->
            {error, 500, Reason}
    end.

step_infer(W) ->
    Params = build_params(W#work.request),
    try erllama:infer(model_id(W), W#work.tokens, Params, W#work.handler) of
        {ok, Ref} ->
            {ok, W#work{infer_ref = Ref}};
        {error, busy} ->
            erllama_server_metrics:inc_pool_exhausted(model_id(W)),
            {error, 429, busy};
        {error, Reason} ->
            {error, 500, Reason}
    catch
        exit:{noproc, {erllama_model, not_found, _}} ->
            {error, 503, not_loaded};
        Class:Why:Stack ->
            log_erllama_crash(model_id(W), infer, Class, Why, Stack),
            {error, 500, model_crashed}
    end.

%% Convert crashes coming back from erllama (gen_statem `call` exits,
%% function clauses inside the model gen_statem, etc.) into a clean
%% error tuple. The request process never dies; the supervisor
%% restart-storm that follows a crashing model still happens upstream
%% but the client sees a JSON 500 instead of a torn HTTP connection.
log_erllama_crash(ModelId, Step, Class, Why, Stack) ->
    logger:error(
        "erllama crash in ~p for ~ts: ~p:~p~n~p",
        [Step, ModelId, Class, Why, Stack]
    ),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

model_id(#work{request = #erllama_request{model_id = Id}}) -> Id.

put_tokens(W, Tokens) ->
    W#work{tokens = Tokens}.

nullable_bin(<<>>) -> undefined;
nullable_bin(B) -> B.

queue_timeout(Model) ->
    case erllama_server_config:pool_policy_for(Model) of
        immediate_429 ->
            0;
        {queue, #{timeout_ms := T}} ->
            T
    end.

build_params(R) ->
    Base = #{
        response_tokens => R#erllama_request.max_tokens,
        temperature => R#erllama_request.temperature,
        top_p => R#erllama_request.top_p,
        top_k => R#erllama_request.top_k,
        min_p => R#erllama_request.min_p,
        stop => R#erllama_request.stop,
        thinking => R#erllama_request.thinking
    },
    Maybe1 = maybe_put(Base, seed, R#erllama_request.seed),
    maybe_put(Maybe1, grammar, R#erllama_request.grammar).

maybe_put(Map, _Key, undefined) -> Map;
maybe_put(Map, Key, Value) -> Map#{Key => Value}.
