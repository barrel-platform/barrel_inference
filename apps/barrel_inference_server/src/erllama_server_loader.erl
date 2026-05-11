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

-module(erllama_server_loader).
-behaviour(gen_server).

-export([start_link/1, await/3, default_opts/1, manifest_to_config/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(APP, erllama_server).

-record(state, {
    model_id :: binary(),
    state :: loading | loaded | {failed, term()},
    %% From, Deadline
    awaiters :: [{gen_server:from(), integer()}]
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

%%====================================================================
%% gen_server
%%====================================================================

init([ModelId]) ->
    self() ! start_load,
    {ok, #state{model_id = ModelId, state = loading, awaiters = []}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.

handle_cast({await, From, Deadline}, S = #state{state = loading, awaiters = A}) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            gen_server:reply(From, {error, load_timeout}),
            {noreply, S};
        false ->
            %% Schedule a self-message at the deadline to expire this
            %% specific awaiter if the load still has not finished.
            erlang:send_after(
                max(0, Deadline - Now),
                self(),
                {expire_awaiter, From}
            ),
            {noreply, S#state{awaiters = [{From, Deadline} | A]}}
    end;
handle_cast({await, From, _Deadline}, S = #state{state = loaded}) ->
    gen_server:reply(From, ok),
    {noreply, S};
handle_cast({await, From, _Deadline}, S = #state{state = {failed, Reason}}) ->
    gen_server:reply(From, {error, Reason}),
    {noreply, S};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(start_load, S = #state{model_id = ModelId}) ->
    Result =
        case default_opts(ModelId) of
            {ok, Opts} -> load_with_opts(ModelId, Opts);
            {error, _} = E -> E
        end,
    NextState =
        case Result of
            ok -> loaded;
            {error, R} -> {failed, R}
        end,
    %% Reply to all current awaiters whose deadlines have not expired.
    Now = erlang:monotonic_time(millisecond),
    Reply =
        case Result of
            ok -> ok;
            {error, R2} -> {error, R2}
        end,
    lists:foreach(
        fun
            ({From, Deadline}) when Deadline >= Now ->
                gen_server:reply(From, Reply);
            (_) ->
                ok
        end,
        S#state.awaiters
    ),
    %% Stay alive on both success AND failure so late-arriving await
    %% casts (the cast race: start_load may fire before the awaiter
    %% registers) get the cached state. The config server's `'DOWN'`
    %% handler removes the loader entry; an explicit retry would need
    %% a separate API in a future version.
    {noreply, S#state{state = NextState, awaiters = []}};
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

load_with_opts(ModelId, Opts) ->
    try erllama:load_model(ModelId, Opts) of
        {ok, _ModelRef} -> ok;
        {error, Reason} -> {error, Reason}
    catch
        Class:Why:_Stack -> {error, {Class, Why}}
    end.

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
    BaseOpts = base_opts(),
    MaxCtx = application:get_env(?APP, max_context_size, 4096),
    NativeCtx = default_int(maps:get(<<"context_size">>, Manifest, undefined), MaxCtx),
    Ctx = min(NativeCtx, MaxCtx),
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

%% erllama_cache_key:quant_byte/1 only knows a fixed subset of quant
%% atoms (f32, f16, q4_0/1, q5_0/1, q8_0, q4_k_m/s, q5_k_m/s, q6_k,
%% q8_k). GGUF labels like q3_k_m, q2_k, iq4_xs, bf16 must be mapped
%% to a supported atom before reaching erllama, otherwise the cache
%% key derivation crashes the model gen_statem.
%%
%% Mapping is by quant bits (closest supported bucket). The model
%% fingerprint already differentiates files, so collapsing several
%% GGUF labels into one cache_key bucket is harmless.
map_to_supported_quant(<<"f32">>) -> f32;
map_to_supported_quant(<<"f16">>) -> f16;
map_to_supported_quant(<<"bf16">>) -> f16;
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
map_to_supported_quant(<<"q2", _/binary>>) -> q4_k_s;
map_to_supported_quant(<<"q3", _/binary>>) -> q4_k_s;
map_to_supported_quant(<<"q4", _/binary>>) -> q4_k_m;
map_to_supported_quant(<<"q5", _/binary>>) -> q5_k_m;
map_to_supported_quant(<<"q6", _/binary>>) -> q6_k;
map_to_supported_quant(<<"q8", _/binary>>) -> q8_0;
map_to_supported_quant(<<"iq1", _/binary>>) -> q4_k_s;
map_to_supported_quant(<<"iq2", _/binary>>) -> q4_k_s;
map_to_supported_quant(<<"iq3", _/binary>>) -> q4_k_s;
map_to_supported_quant(<<"iq4", _/binary>>) -> q4_k_m;
map_to_supported_quant(_) -> f16.

default_int(undefined, Default) -> Default;
default_int(null, Default) -> Default;
default_int(N, _) when is_integer(N), N > 0 -> N;
default_int(_, Default) -> Default.
