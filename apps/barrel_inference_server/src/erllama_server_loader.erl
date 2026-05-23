%%% Per-model loader. Owns the (synchronous) erllama:load_model/2 call
%%% so that the config gen_server stays responsive. Multiple
%%% concurrent ensure_loaded/1 callers for the same model attach their
%%% From + Deadline to this loader; on completion (success or error)
%%% the loader replies to all of them, then exits normally.
%%%
%%% Time-bounded waiters whose deadline elapses while the load is
%%% still in flight are removed from the awaiter list and replied
%%% {error, load_timeout}. The loader keeps running because other
%%% awaiters may have longer deadlines, and so the next request finds
%%% the model already loaded.
%%%
%%% The actual erllama:load_model/2 call runs in a spawn_monitor'd
%%% worker so the loader gen_server stays responsive to subscribe
%%% casts and `progress_tick` timer messages while the load is in
%%% flight. Subscribers receive:
%%%
%%%   {erllama_load_progress, ModelId}              periodic, every 2 s
%%%   {erllama_load_done, ModelId, ok}              on success
%%%   {erllama_load_done, ModelId, {error, Reason}} on failure

-module(erllama_server_loader).
-behaviour(gen_server).

-export([
    start_link/1,
    await/3,
    subscribe/2,
    default_opts/1,
    manifest_to_config/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(APP, erllama_server).
-define(TICK_INTERVAL_MS, 2000).

-record(state, {
    model_id :: binary(),
    state :: loading | loaded | {failed, term()},
    %% From, Deadline (gen_server:reply targets)
    awaiters :: [{gen_server:from(), integer()}],
    %% Pids that receive {erllama_load_progress|done, ModelId, ...}
    subscribers :: [pid()],
    tick_timer :: undefined | reference(),
    worker :: undefined | {pid(), reference()},
    load_started_at :: undefined | integer(),
    %% Monitor on the underlying erllama_model gen_statem once it is
    %% registered. The loader exits when this fires so the config
    %% server's 'DOWN' handler removes its entry from `state.loaders`
    %% and the next ensure_loaded creates a fresh loader. Without
    %% this the loader latches `loaded` even after the keep_alive
    %% subsystem (or a manual unload) tears the gen_statem down.
    model_mon :: undefined | reference()
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(ModelId) ->
    gen_server:start_link(?MODULE, [ModelId], []).

%% Cast our identity to the loader. The config server uses this to
%% park a caller's `From` until the loader finishes; the loader then
%% calls `gen_server:reply(From, ok | {error, _})`.
-spec await(pid(), gen_server:from(), integer()) -> ok.
await(Loader, From, Deadline) ->
    gen_server:cast(Loader, {await, From, Deadline}).

%% Subscribe a pid for progress + done messages. If the model is
%% already loaded or failed, the corresponding `done` message is sent
%% immediately. Otherwise the subscriber receives a `progress` message
%% every TICK_INTERVAL_MS while the load is in flight, then exactly
%% one `done` message.
-spec subscribe(pid(), pid()) -> ok.
subscribe(Loader, Pid) when is_pid(Pid) ->
    gen_server:cast(Loader, {subscribe, Pid}).

%%====================================================================
%% gen_server
%%====================================================================

init([ModelId]) ->
    self() ! start_load,
    {ok, #state{
        model_id = ModelId,
        state = loading,
        awaiters = [],
        subscribers = [],
        tick_timer = undefined,
        worker = undefined,
        load_started_at = undefined,
        model_mon = undefined
    }}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.

handle_cast({await, From, Deadline}, S = #state{state = loading, awaiters = A}) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            gen_server:reply(From, {error, load_timeout}),
            {noreply, S};
        false ->
            erlang:send_after(
                max(0, Deadline - Now),
                self(),
                {expire_awaiter, From}
            ),
            {noreply, S#state{awaiters = [{From, Deadline} | A]}}
    end;
handle_cast({await, From, _Deadline}, S = #state{state = loaded, model_id = Id}) ->
    case model_alive(Id) of
        true ->
            gen_server:reply(From, ok),
            {noreply, S};
        false ->
            gen_server:reply(From, {error, not_loaded}),
            {stop, normal, S}
    end;
handle_cast({await, From, _Deadline}, S = #state{state = {failed, Reason}}) ->
    gen_server:reply(From, {error, Reason}),
    {noreply, S};
handle_cast({subscribe, Pid}, S = #state{state = loading, subscribers = Subs}) ->
    {noreply, S#state{subscribers = lists:usort([Pid | Subs])}};
handle_cast({subscribe, Pid}, S = #state{state = loaded, model_id = Id}) ->
    case model_alive(Id) of
        true ->
            Pid ! {erllama_load_done, Id, ok},
            {noreply, S};
        false ->
            Pid ! {erllama_load_done, Id, {error, not_loaded}},
            {stop, normal, S}
    end;
handle_cast({subscribe, Pid}, S = #state{state = {failed, Reason}, model_id = Id}) ->
    Pid ! {erllama_load_done, Id, {error, Reason}},
    {noreply, S};
handle_cast({load_result, WorkerPid, Result}, S = #state{worker = {WorkerPid, _Mon}}) ->
    finalize(S, Result);
handle_cast({load_result, _, _}, S) ->
    {noreply, S};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(start_load, S = #state{model_id = ModelId}) ->
    %% Resolve options on the loader process: this is fast (just a
    %% manifest read). The slow part (erllama:load_model/2) runs in
    %% a worker so the gen_server stays responsive.
    case default_opts(ModelId) of
        {ok, Opts} ->
            {Pid, Mon} = spawn_load_worker(self(), ModelId, Opts),
            {noreply,
                schedule_tick(S#state{
                    worker = {Pid, Mon},
                    load_started_at = erlang:monotonic_time(millisecond)
                })};
        {error, _} = E ->
            finalize(S, E)
    end;
handle_info({progress_tick, _Ref}, S = #state{state = loading}) ->
    #state{subscribers = Subs, model_id = Id} = S,
    _ = [Pid ! {erllama_load_progress, Id} || Pid <- Subs],
    {noreply, schedule_tick(S)};
handle_info({progress_tick, _}, S) ->
    {noreply, S};
handle_info({'DOWN', Mon, process, Pid, Reason}, S = #state{state = loading}) ->
    case S#state.worker of
        {Pid, Mon} ->
            finalize(S, {error, {load_worker_crashed, Reason}});
        _ ->
            {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _, _Reason}, S = #state{model_mon = Mon}) ->
    {stop, normal, S};
handle_info({expire_awaiter, From}, S = #state{state = loading, awaiters = A}) ->
    case lists:keytake(From, 1, A) of
        {value, {From, _}, A1} ->
            gen_server:reply(From, {error, load_timeout}),
            {noreply, S#state{awaiters = A1}};
        false ->
            {noreply, S}
    end;
handle_info({expire_awaiter, _}, S) ->
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

spawn_load_worker(LoaderPid, ModelId, Opts) ->
    spawn_monitor(fun() ->
        Result = load_with_opts(ModelId, Opts),
        gen_server:cast(LoaderPid, {load_result, self(), Result})
    end).

load_with_opts(ModelId, Opts) ->
    try erllama:load_model(ModelId, Opts) of
        {ok, _ModelRef} ->
            ok;
        {error, already_loaded} ->
            %% Race: the previous gen_statem died but the registry
            %% gen_server has not yet processed the 'DOWN' that
            %% removes the ETS row, so register_name/2 fell through.
            %% Clear the stale entry and retry once.
            _ = erllama_registry:unregister_name(ModelId),
            try erllama:load_model(ModelId, Opts) of
                {ok, _} -> ok;
                {error, R} -> {error, R}
            catch
                C:W:_ -> {error, {C, W}}
            end;
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Why:_Stack -> {error, {Class, Why}}
    end.

%% Reply to all current awaiters whose deadlines have not expired,
%% then fan out the final done message to subscribers.
finalize(S = #state{model_id = Id, awaiters = A, subscribers = Subs, worker = W}, Result) ->
    Now = erlang:monotonic_time(millisecond),
    Reply =
        case Result of
            ok -> ok;
            {error, _} = E -> E
        end,
    _ = [gen_server:reply(From, Reply) || {From, Deadline} <- A, Deadline >= Now],
    _ = [Pid ! {erllama_load_done, Id, Reply} || Pid <- Subs],
    NextState =
        case Result of
            ok -> loaded;
            {error, R} -> {failed, R}
        end,
    S1 = cancel_tick(cancel_worker(W, S)),
    S2 = S1#state{
        state = NextState,
        awaiters = [],
        subscribers = [],
        load_started_at = undefined
    },
    case NextState of
        loaded -> attach_model_monitor(S2);
        _ -> {noreply, S2}
    end.

%% After a successful load, monitor the gen_statem the load just
%% registered. When it goes away (keep_alive timer fires, manual
%% unload, crash) we exit so the config server's 'DOWN' handler
%% drops our stale entry and the next ensure_loaded creates a fresh
%% loader. Without this, the loaded-state cache replies `ok` to new
%% callers and the pipeline crashes on the next gen_statem:call
%% with {noproc, {erllama_model, not_found, _}}.
attach_model_monitor(S = #state{model_id = Id}) ->
    case erllama_registry:whereis_name(Id) of
        Pid when is_pid(Pid) ->
            Mon = erlang:monitor(process, Pid),
            {noreply, S#state{model_mon = Mon}};
        undefined ->
            {stop, normal, S}
    end.

%% Cheap registry probe used by the loaded-state cast handlers to
%% catch a model that's already been torn down between finalize and
%% the next subscribe.
model_alive(Id) ->
    case erllama_registry:whereis_name(Id) of
        Pid when is_pid(Pid) -> is_process_alive(Pid);
        _ -> false
    end.

cancel_worker(undefined, S) ->
    S#state{worker = undefined};
cancel_worker({_Pid, Mon}, S) ->
    _ = erlang:demonitor(Mon, [flush]),
    S#state{worker = undefined}.

schedule_tick(S) ->
    Ref = make_ref(),
    Timer = erlang:send_after(?TICK_INTERVAL_MS, self(), {progress_tick, Ref}),
    S#state{tick_timer = Timer}.

cancel_tick(S = #state{tick_timer = T}) when is_reference(T) ->
    _ = erlang:cancel_timer(T),
    S#state{tick_timer = undefined};
cancel_tick(S) ->
    S#state{tick_timer = undefined}.

%% Resolve a model id into the erllama:load_model/2 config map by
%% looking up its manifest in the registry. With `auto_pull` enabled,
%% an unknown model is fetched on the fly. Otherwise the loader
%% reports `{error, not_found}`, which pipeline.erl maps to 404.
-spec default_opts(binary()) -> {ok, map()} | {error, term()}.
default_opts(ModelId) ->
    case erllama_server_models:get(ModelId) of
        {ok, Manifest} ->
            {ok, manifest_to_config(Manifest)};
        {error, not_found} ->
            handle_missing(ModelId);
        {error, _} = E ->
            E
    end.

handle_missing(ModelId) ->
    case erllama_server_config:auto_pull() of
        true ->
            case erllama_server_models:pull(ModelId) of
                {ok, Manifest} -> {ok, manifest_to_config(Manifest)};
                {error, _} -> {error, not_found}
            end;
        false ->
            {error, not_found}
    end.

%% Map a manifest into the option set erllama:load_model/2 expects.
%% Fields not present in the manifest fall through to app-env defaults
%% (`tier_srv`, `tier`, `policy`, `ctx_params_hash`); operators wire
%% those once at boot.
-spec manifest_to_config(map()) -> map().
manifest_to_config(Manifest) ->
    Loader = maps:get(<<"loader">>, Manifest, #{}),
    Params = maps:get(<<"parameters">>, Manifest, #{}),
    BaseOpts = base_opts(),
    MaxCtx = application:get_env(?APP, max_context_size, 4096),
    %% Modelfile PARAMETER num_ctx overrides the GGUF advertised value
    %% (but the server-wide max_context_size still caps it).
    ParamCtx = maps:get(<<"num_ctx">>, Params, undefined),
    NativeCtx = default_int(maps:get(<<"context_size">>, Manifest, undefined), MaxCtx),
    Ctx = min(default_int(ParamCtx, NativeCtx), MaxCtx),
    %% n_batch sizes the per-call prefill batch the engine submits
    %% to llama.cpp. The compute buffer scales with `n_layers *
    %% n_embd * n_batch'; bigger = faster prefill, more memory.
    %% Resolution: `parameters.num_batch' (operator override via
    %% /api/edit) > `loader.n_batch' (as-pulled) > parameter-size
    %% heuristic > 2048 fallback. Ollama-style `num_X' on the wire,
    %% `n_X' on the loader, matches the existing `num_ctx -> n_ctx'
    %% mapping at line 331.
    NBatch = default_int(
        maps:get(<<"num_batch">>, Params, undefined),
        default_int(
            maps:get(<<"n_batch">>, Loader, undefined),
            default_n_batch(Manifest)
        )
    ),
    %% `n_seq_max` controls the engine's seq pool. Sticky-seq
    %% pinning (PR 28+) and the continue/3 path (PR 32) need at
    %% least 2 here to avoid admission deadlock the moment a second
    %% session arrives; documented in guides/clients.md. Resolution
    %% mirrors n_batch: `parameters.num_seq_max' > `loader.n_seq_max'
    %% > engine default (1). When undefined the loader leaves the
    %% key off `context_opts' and the engine picks its own default.
    NSeqMax = pos_int(
        maps:get(
            <<"num_seq_max">>,
            Params,
            maps:get(<<"n_seq_max">>, Loader, undefined)
        )
    ),
    %% erllama 0.8.0 bounds each decode step at a per-step wall-clock
    %% budget (`context_opts.decode_budget_ms', engine default 30000,
    %% 0 disables) so a wedged decode aborts and the engine recovers in
    %% place instead of blocking forever. Resolution mirrors n_seq_max:
    %% `parameters.num_decode_budget_ms' > `loader.decode_budget_ms' >
    %% global `decode_budget_ms' app env. Undefined leaves the key off
    %% so the engine keeps its own default.
    DecodeBudget = non_neg_int(
        maps:get(
            <<"num_decode_budget_ms">>,
            Params,
            maps:get(
                <<"decode_budget_ms">>,
                Loader,
                application:get_env(?APP, decode_budget_ms, undefined)
            )
        )
    ),
    %% erllama_model_llama reads `context_opts` (forwarded to
    %% erllama_nif:new_context/2) and `model_opts` (forwarded to
    %% erllama_nif:load_model/2). Without these the NIF falls back to
    %% llama.cpp's defaults — most importantly n_ctx=512, which is far
    %% too small for SDK clients that ship system + tool definitions
    %% in the first turn and causes a hard segfault during prefill
    %% when the input overflows the context.
    %%
    %% n_gpu_layers is opt-in: only forward it when the manifest (or
    %% a Modelfile PARAMETER) sets a positive value. Otherwise we'd
    %% override llama.cpp's platform default (offload-all on Metal /
    %% CUDA / ROCm) with the manifest's 0 placeholder and force CPU
    %% inference, which is slow and breaks the compute-buffer sizing
    %% for the larger contexts SDK clients send.
    Config0 = BaseOpts#{
        backend => application:get_env(?APP, model_backend, erllama_model_llama),
        model_path => path_string(maps:get(<<"blob_path">>, Manifest)),
        fingerprint => fingerprint_from_digest(maps:get(<<"digest">>, Manifest, null)),
        fingerprint_mode => application:get_env(?APP, fingerprint_mode, safe),
        quant_type => quant_atom(maps:get(<<"quantization">>, Manifest, null)),
        quant_bits => default_int(maps:get(<<"quant_bits">>, Loader, undefined), 4),
        context_size => Ctx,
        context_opts => maybe_put_decode_budget_ms(
            maybe_put_n_seq_max(
                #{n_ctx => Ctx, n_batch => NBatch},
                NSeqMax
            ),
            DecodeBudget
        ),
        model_opts => model_opts_from(Loader, Params)
    },
    Config1 = maybe_put_thinking_markers(Config0, Loader),
    maybe_put_tool_call_markers(Config1, Loader).

%% erllama 0.4.0 takes per-model extended-thinking markers via
%% `thinking_markers => #{start := Bin, end := Bin}` on load_model/2.
%% Operators declare them in the manifest's loader section per
%% model family (qwen3 uses <think>/</think>, deepseek-r1 different
%% strings, etc.). Omitting the markers disables thinking for that
%% model.
maybe_put_thinking_markers(Config, Loader) ->
    case maps:get(<<"thinking_markers">>, Loader, undefined) of
        #{<<"start">> := Start, <<"end">> := End} when
            is_binary(Start), is_binary(End), Start =/= <<>>, End =/= <<>>
        ->
            Config#{thinking_markers => #{start => Start, 'end' => End}};
        _ ->
            Config
    end.

%% erllama 0.5.0 takes per-model tool-call markers via
%% `tool_call_markers => #{start := Bin, end := Bin, ...}` on
%% load_model/2. Operators declare them in the manifest's loader
%% section per model family (qwen-xml uses <tool_call>/</tool_call>,
%% etc.). With markers set, the engine builds a deterministic
%% greedy-on-syntax sampler and emits `tool_call_delta` /
%% `erllama_tool_call_end` wire messages. Optional payload_start /
%% payload_end mark string regions inside the span that flip back
%% to the request's normal sampler for caller-supplied content.
maybe_put_tool_call_markers(Config, Loader) ->
    case maps:get(<<"tool_call_markers">>, Loader, undefined) of
        #{<<"start">> := Start, <<"end">> := End} = M when
            is_binary(Start), is_binary(End), Start =/= <<>>, End =/= <<>>
        ->
            Base = #{start => Start, 'end' => End},
            Config#{tool_call_markers => add_payload_markers(Base, M)};
        _ ->
            Config
    end.

add_payload_markers(Base, #{<<"payload_start">> := PS, <<"payload_end">> := PE}) when
    is_binary(PS), is_binary(PE), PS =/= <<>>, PE =/= <<>>
->
    Base#{payload_start => PS, payload_end => PE};
add_payload_markers(Base, _) ->
    Base.

%% Normalise an optional positive-integer manifest field. Anything
%% else (null, missing, 0, non-integer) collapses to `undefined' so
%% the caller can decide on the default.
pos_int(N) when is_integer(N), N > 0 -> N;
pos_int(_) -> undefined.

%% Like pos_int/1 but 0 is valid (0 disables the decode budget).
non_neg_int(N) when is_integer(N), N >= 0 -> N;
non_neg_int(_) -> undefined.

maybe_put_n_seq_max(Opts, undefined) -> Opts;
maybe_put_n_seq_max(Opts, N) -> Opts#{n_seq_max => N}.

maybe_put_decode_budget_ms(Opts, undefined) -> Opts;
maybe_put_decode_budget_ms(Opts, N) -> Opts#{decode_budget_ms => N}.

%% Build the model_opts map. Only set keys the manifest actually
%% supplies; let llama.cpp pick its own platform-appropriate default
%% for everything else (in particular, `n_gpu_layers` defaults to
%% offload-all on GPU builds).
model_opts_from(Loader, Params) ->
    Sources = [
        {n_gpu_layers, <<"n_gpu_layers">>},
        {main_gpu, <<"main_gpu">>},
        {use_mmap, <<"use_mmap">>},
        {use_mlock, <<"use_mlock">>}
    ],
    lists:foldl(
        fun({Atom, BinKey}, Acc) ->
            case manifest_param(BinKey, Loader, Params) of
                undefined -> Acc;
                Value -> Acc#{Atom => Value}
            end
        end,
        #{},
        Sources
    ).

%% Modelfile PARAMETER (Params) takes precedence over the manifest's
%% loader sub-map. n_gpu_layers must be a positive integer to count
%% as a deliberate override; 0 / null / missing means "let the NIF
%% pick its platform default".
manifest_param(Key, Loader, Params) ->
    case maps:get(Key, Params, maps:get(Key, Loader, undefined)) of
        undefined -> undefined;
        null -> undefined;
        0 when Key =:= <<"n_gpu_layers">> -> undefined;
        Value -> Value
    end.

base_opts() ->
    application:get_env(?APP, model_default_opts, #{}).

path_string(B) when is_binary(B) -> unicode:characters_to_list(B);
path_string(L) when is_list(L) -> L.

fingerprint_from_digest(<<"sha256:", Hex/binary>>) ->
    case hex_to_bin(Hex) of
        Bin when byte_size(Bin) =:= 32 -> Bin;
        _ -> binary:copy(<<0>>, 32)
    end;
fingerprint_from_digest(_) ->
    binary:copy(<<0>>, 32).

hex_to_bin(Hex) ->
    try
        <<<<(list_to_integer([A, B], 16))>> || <<A, B>> <= Hex>>
    catch
        _:_ -> <<>>
    end.

quant_atom(undefined) -> f16;
quant_atom(null) -> f16;
quant_atom(Bin) when is_binary(Bin) -> map_to_supported_quant(Bin);
quant_atom(_) -> f16.

%% Pre-Bucket-A workaround: even with upstream erllama_cache_key now
%% covering every llama.cpp ftype value, this mapping keeps responses
%% stable across erllama versions and short-circuits any future
%% additions before they reach the cache key derivation. The mapping
%% is by quant bits (closest supported bucket).
map_to_supported_quant(<<"f32">>) -> f32;
map_to_supported_quant(<<"f16">>) -> f16;
map_to_supported_quant(<<"bf16">>) -> bf16;
map_to_supported_quant(<<"q4_0">>) -> q4_0;
map_to_supported_quant(<<"q4_1">>) -> q4_1;
map_to_supported_quant(<<"q5_0">>) -> q5_0;
map_to_supported_quant(<<"q5_1">>) -> q5_1;
map_to_supported_quant(<<"q8_0">>) -> q8_0;
map_to_supported_quant(<<"q4_k_m">>) -> q4_k_m;
map_to_supported_quant(<<"q4_k_s">>) -> q4_k_s;
map_to_supported_quant(<<"q5_k_m">>) -> q5_k_m;
map_to_supported_quant(<<"q5_k_s">>) -> q5_k_s;
map_to_supported_quant(<<"q6_k">>) -> q6_k;
map_to_supported_quant(<<"q8_k">>) -> q8_k;
map_to_supported_quant(<<"q2", _/binary>>) -> q2_k;
map_to_supported_quant(<<"q3_k_s">>) -> q3_k_s;
map_to_supported_quant(<<"q3_k_m">>) -> q3_k_m;
map_to_supported_quant(<<"q3_k_l">>) -> q3_k_l;
map_to_supported_quant(<<"q3", _/binary>>) -> q3_k_m;
map_to_supported_quant(<<"iq1", _/binary>>) -> iq1_s;
map_to_supported_quant(<<"iq2", _/binary>>) -> iq2_s;
map_to_supported_quant(<<"iq3", _/binary>>) -> iq3_s;
map_to_supported_quant(<<"iq4_nl">>) -> iq4_nl;
map_to_supported_quant(<<"iq4", _/binary>>) -> iq4_xs;
map_to_supported_quant(_) -> f16.

default_int(undefined, Default) -> Default;
default_int(null, Default) -> Default;
default_int(N, _) when is_integer(N), N > 0 -> N;
default_int(_, Default) -> Default.

%% Pick a sensible `n_batch' default from the manifest's
%% `parameter_size' label (`"7B"', `"30B"', `"70B"', `"0.5B"', ...).
%% The compute buffer llama.cpp allocates for a prefill step scales
%% with `n_layers * n_embd * n_batch'; larger models can OOM at
%% 2048 on hosts that fit smaller models comfortably. Brackets are
%% conservative numbers that have been observed safe on Metal /
%% unified-memory hosts. Returns 2048 when the manifest lacks
%% `parameter_size' or the label cannot be parsed - matches
%% llama.cpp's own default and is the safe choice for anything <= 8B
%% which is the most common case.
default_n_batch(Manifest) ->
    case parameter_size_billions(Manifest) of
        undefined -> 2048;
        N when N =< 13.0 -> 2048;
        N when N =< 33.0 -> 1024;
        _ -> 512
    end.

parameter_size_billions(Manifest) ->
    case maps:get(<<"parameter_size">>, Manifest, undefined) of
        Bin when is_binary(Bin) -> parse_billions(Bin);
        _ -> undefined
    end.

parse_billions(Bin) ->
    case
        re:run(Bin, <<"^(\\d+(?:\\.\\d+)?)[BMK]?$">>, [
            {capture, all_but_first, binary}
        ])
    of
        {match, [NumBin]} ->
            try binary_to_float(NumBin) of
                F -> F
            catch
                _:_ ->
                    try binary_to_integer(NumBin) of
                        I -> float(I)
                    catch
                        _:_ -> undefined
                    end
            end;
        _ ->
            undefined
    end.
