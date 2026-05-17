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
    Messages = R#erllama_request.messages,
    System = R#erllama_request.system,
    Tools = R#erllama_request.tools,
    %% Walk the message history before rendering so the exact-replay
    %% counters reflect what fraction of prior tool_use blocks land a
    %% hit in the replay map. Once erllama exposes a verbatim-content
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
    case erllama_server_tool_format:lookup(Model) of
        not_found ->
            erllama_server_metrics:inc_tool_replay_lookup(Model, no_format);
        {ok, _Spec} ->
            case erllama_server_tool_replay:get(Id) of
                {ok, _} ->
                    erllama_server_metrics:inc_tool_replay_lookup(Model, hit);
                not_found ->
                    erllama_server_metrics:inc_tool_replay_lookup(Model, miss)
            end
    end;
note_tool_use_block(_Model, _) ->
    ok.

%% Render the chat template; if the resulting token count would
%% overflow n_ctx, drop the oldest non-system message and retry.
%% Mirrors Ollama's `server/prompt.go` truncation strategy: preserve
%% system + the final (most recent) message, shave from the head.
%% Cap retries so a single oversized final turn fails cleanly with
%% 413 rather than looping. llama.cpp would otherwise segfault when
%% the prefill batch token count >= n_ctx.
apply_chat_template_with_truncate(W, System, Tools, Messages) ->
    case render_template(W, System, Tools, Messages) of
        {ok, Tokens} ->
            case fits_context(W, length(Tokens)) of
                ok ->
                    accept_tokens(W, Tokens);
                {error, 503, _} = E ->
                    E;
                {overflow, Ctx} when length(Messages) =< 1 ->
                    {error, 413, #{
                        error => context_overflow,
                        prompt_tokens => length(Tokens),
                        context_size => Ctx
                    }};
                {overflow, _Ctx} ->
                    apply_chat_template_with_truncate(
                        W, System, Tools, drop_oldest_non_system(Messages)
                    )
            end;
        {error, _, _} = E ->
            E
    end.

render_template(W, System, Tools, Messages) ->
    Req = #{messages => Messages, system => System, tools => Tools},
    try erllama:apply_chat_template(model_id(W), Req) of
        {ok, Tokens} -> {ok, Tokens};
        {error, no_template} -> {error, 501, no_chat_template};
        {error, not_supported} -> {error, 501, chat_template_not_supported};
        {error, Reason} -> {error, 400, Reason}
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
            case fits_context(W, length(Tokens)) of
                ok ->
                    accept_tokens(W, Tokens);
                {error, _, _} = E ->
                    E;
                {overflow, Ctx} ->
                    {error, 413, #{
                        error => context_overflow,
                        prompt_tokens => length(Tokens),
                        context_size => Ctx
                    }}
            end;
        {error, Reason} ->
            {error, 400, Reason}
    catch
        exit:{noproc, {erllama_model, not_found, _}} ->
            {error, 503, not_loaded};
        Class:Why:Stack ->
            log_erllama_crash(model_id(W), tokenize, Class, Why, Stack),
            {error, 500, model_crashed}
    end.

accept_tokens(W, Tokens) ->
    W1 = put_tokens(W, Tokens),
    W#work.handler ! {pipeline, templated, Tokens},
    {ok, W1}.

%% Returns `ok` if the prompt fits, `{overflow, Ctx}` if it doesn't,
%% or `{error, 503, not_loaded}` if the model has gone away between
%% load and template. Reading context_size via model_info is a single
%% gen_statem:call into the model itself; cheap enough to call once
%% per template attempt.
fits_context(W, NToks) ->
    case context_size(model_id(W)) of
        undefined -> {error, 503, not_loaded};
        Ctx when NToks >= Ctx -> {overflow, Ctx};
        _Ctx -> ok
    end.

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
        %% erllama 0.5.0: two concurrent admits on the same session_id
        %% are out of scope - the second returns sticky_busy. Map to a
        %% retryable 503; the Anthropic handler further remaps 503 to
        %% 529 with a retry-after header that SDKs honour as the next
        %% backoff delay.
        {error, sticky_busy} ->
            {error, 503, sticky_busy};
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
        %% erllama 0.3.0 renamed the placeholder `stop` to
        %% `stop_sequences` and wired it up: generation halts on the
        %% first match in the accumulated detokenised output and the
        %% matched binary comes back in Stats.
        stop_sequences => R#erllama_request.stop,
        thinking => R#erllama_request.thinking
    },
    Maybe1 = maybe_put(Base, seed, R#erllama_request.seed),
    Maybe2 = maybe_put(Maybe1, grammar, R#erllama_request.grammar),
    %% erllama 0.4.0 accepts thinking_budget_tokens as a caller-side cap
    %% on extended-thinking length. Forward Anthropic's
    %% thinking.budget_tokens through when set and positive; the engine
    %% treats absent / non-positive as "no cap".
    Maybe3 = maybe_put(Maybe2, thinking_budget_tokens, R#erllama_request.thinking_budget),
    %% erllama 0.5.0 pins the underlying seq_id to whatever session_id
    %% Params carries. The next turn on the same id truncates-and-
    %% prefills in place on the live KV cells instead of warm-restoring
    %% from disk. Cancel is async (next decode tick observes it) so a
    %% retry with the same session_id during that window gets
    %% `{error, sticky_busy}` -> 503; SDKs honour Retry-After.
    maybe_put(Maybe3, session_id, R#erllama_request.session_id).

maybe_put(Map, _Key, undefined) -> Map;
maybe_put(Map, Key, Value) -> Map#{Key => Value}.
