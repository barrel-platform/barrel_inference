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
    BaseOpts#{
        backend => application:get_env(?APP, model_backend, erllama_model_llama),
        model_path => path_string(maps:get(<<"blob_path">>, Manifest)),
        fingerprint => fingerprint_from_digest(maps:get(<<"digest">>, Manifest, null)),
        fingerprint_mode => application:get_env(?APP, fingerprint_mode, safe),
        quant_type => quant_atom(maps:get(<<"quantization">>, Manifest, null)),
        quant_bits => default_int(maps:get(<<"quant_bits">>, Loader, undefined), 4),
        context_size => Ctx
    }.

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
