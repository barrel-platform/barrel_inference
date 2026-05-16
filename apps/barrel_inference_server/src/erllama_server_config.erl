%%% Server-wide configuration: model aliases, load policy, request
%%% timeouts, body limits. Also the dispatcher for ensure_loaded/1,
%%% which routes load attempts to per-model erllama_server_loader
%%% workers so the config server itself never blocks on a model load.

-module(erllama_server_config).
-behaviour(gen_server).

-export([start_link/0]).

-export([
    resolve_model/1,
    set_aliases/1,
    load_policy/0,
    ensure_loaded/1,
    max_request_body_bytes/0,
    max_embedding_inputs/0,
    max_messages/0,
    max_tools/0,
    generation_idle_ms/0,
    prefill_ms/0,
    total_ms/0,
    generation_ping_ms/0,
    anthropic_api_keys/0,
    anthropic_retry_after_seconds/0,
    tool_call_formats/0,
    pool_policy_for/1,
    tracing_config/0,
    cors/0,
    request_id_header/0,
    auto_pull/0,
    keep_alive_default_ms/0,
    ensure_loaded_async/3
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(APP, erllama_server).

-record(state, {
    aliases :: #{binary() => binary()},
    load_policy :: on_demand | preloaded | reject,
    pool_policy :: pool_policy(),
    per_model_pool_policy :: #{binary() => pool_policy()},
    %% ModelId -> {LoaderPid, MonRef} for in-flight on-demand loads.
    loaders = #{} :: #{binary() => {pid(), reference()}}
}).

-type pool_policy() ::
    immediate_429
    | {queue, #{
        concurrency := pos_integer(),
        depth := pos_integer(),
        timeout_ms := pos_integer()
    }}.

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec resolve_model(binary()) -> binary().
resolve_model(Requested) when is_binary(Requested) ->
    %% Alias-or-identity passthrough. Stays out of the gen_server hot
    %% path by reading from persistent_term, which is updated on
    %% set_aliases/1.
    Map = persistent_term:get({?MODULE, aliases}, #{}),
    maps:get(Requested, Map, Requested).

-spec set_aliases(#{binary() => binary()}) -> ok.
set_aliases(Map) when is_map(Map) ->
    gen_server:cast(?MODULE, {set_aliases, Map}).

-spec load_policy() -> on_demand | preloaded | reject.
load_policy() ->
    persistent_term:get({?MODULE, load_policy}, on_demand).

-spec pool_policy_for(binary()) -> pool_policy().
pool_policy_for(ModelId) ->
    Per = persistent_term:get({?MODULE, per_model_pool_policy}, #{}),
    case maps:find(ModelId, Per) of
        {ok, P} -> P;
        error -> persistent_term:get({?MODULE, pool_policy})
    end.

-spec max_request_body_bytes() -> pos_integer().
max_request_body_bytes() ->
    persistent_term:get({?MODULE, max_request_body_bytes}, 33554432).

-spec max_embedding_inputs() -> pos_integer().
max_embedding_inputs() ->
    persistent_term:get({?MODULE, max_embedding_inputs}, 256).

-spec generation_idle_ms() -> pos_integer().
generation_idle_ms() ->
    persistent_term:get({?MODULE, generation_idle_timeout_ms}, 60000).

-spec prefill_ms() -> pos_integer().
prefill_ms() ->
    persistent_term:get({?MODULE, prefill_timeout_ms}, 300000).

-spec total_ms() -> pos_integer().
total_ms() ->
    persistent_term:get({?MODULE, max_total_ms}, 1800000).

%% Cadence for the Anthropic-style ping SSE frame during active
%% generation. Keeps SDK idle timers and proxy connections alive when
%% the model is slow between tokens.
-spec generation_ping_ms() -> pos_integer().
generation_ping_ms() ->
    persistent_term:get({?MODULE, generation_ping_ms}, 15000).

%% Optional allowlist of accepted x-api-key values for the Anthropic
%% Messages routes. Empty list (default) disables authentication so
%% Claude Code can hit the endpoint with any value out of the box.
%% Set to a non-empty list to enforce.
-spec anthropic_api_keys() -> [binary()].
anthropic_api_keys() ->
    persistent_term:get({?MODULE, anthropic_api_keys}, []).

%% Seconds advertised in the `retry-after` header on Anthropic 529
%% responses (engine overloaded / model not ready). SDKs honour this
%% as the next backoff delay.
-spec anthropic_retry_after_seconds() -> pos_integer().
anthropic_retry_after_seconds() ->
    persistent_term:get({?MODULE, anthropic_retry_after_seconds}, 5).

%% Per-format tool-call registry used by erllama_server_tool_format.
%% Built-in defaults cover the open-weights families erllama_server
%% ships parsers for; operators may merge additional entries via the
%% `tool_call_formats` app env (the init merge keeps both).
-spec tool_call_formats() -> #{binary() => map()}.
tool_call_formats() ->
    persistent_term:get({?MODULE, tool_call_formats}, default_tool_call_formats()).

default_tool_call_formats() ->
    #{
        <<"qwen-xml">> => #{module => erllama_server_tool_format_qwen_xml}
    }.

-spec tracing_config() -> off | {otlp, binary()}.
tracing_config() ->
    persistent_term:get({?MODULE, tracing}, off).

-spec max_messages() -> pos_integer().
max_messages() ->
    persistent_term:get({?MODULE, max_messages}, 1024).

-spec max_tools() -> pos_integer().
max_tools() ->
    persistent_term:get({?MODULE, max_tools}, 128).

-spec cors() -> off | map().
cors() ->
    persistent_term:get({?MODULE, cors}, off).

-spec request_id_header() -> binary().
request_id_header() ->
    persistent_term:get({?MODULE, request_id_header}, <<"x-request-id">>).

-spec auto_pull() -> boolean().
auto_pull() ->
    persistent_term:get({?MODULE, auto_pull}, false).

-spec keep_alive_default_ms() -> non_neg_integer() | infinity.
keep_alive_default_ms() ->
    persistent_term:get({?MODULE, keep_alive_default_ms}, 300000).

%% Synchronous on a successful in-cache check; otherwise the call is
%% un-replied and the loader process replies later. Caller's deadline
%% is honoured by the loader.
-spec ensure_loaded(binary()) -> ok | {error, atom()}.
ensure_loaded(ModelId) when is_binary(ModelId) ->
    Deadline = erlang:monotonic_time(millisecond) + prefill_ms(),
    gen_server:call(?MODULE, {ensure_loaded, ModelId, Deadline}, prefill_ms() + 1000).

%% Asynchronous variant used by the pipeline so it can stream
%% `{erllama_load_progress, ModelId}` lines to the client. Returns
%% `ok` synchronously after subscribing `Caller`; the caller then
%% receives:
%%
%%   {erllama_load_progress, ModelId}              every 2 s while loading
%%   {erllama_load_done, ModelId, ok | {error, _}} exactly once
%%
%% A `ready` fast-check shortcut delivers the `done` message
%% immediately; the caller's receive loop sees the same shape either
%% way.
-spec ensure_loaded_async(binary(), pid(), integer()) -> ok | {error, atom()}.
ensure_loaded_async(ModelId, Caller, _Deadline) when is_binary(ModelId), is_pid(Caller) ->
    gen_server:call(?MODULE, {ensure_loaded_async, ModelId, Caller}).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    Aliases = app_env(model_aliases, #{}),
    LoadPolicy = app_env(model_load_policy, on_demand),
    PoolPolicy = app_env(
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 100, timeout_ms => 30000}}
    ),
    PerModel = app_env(per_model_pool_exhausted_policy, #{}),
    persistent_term:put({?MODULE, aliases}, Aliases),
    persistent_term:put({?MODULE, load_policy}, LoadPolicy),
    persistent_term:put({?MODULE, pool_policy}, PoolPolicy),
    persistent_term:put({?MODULE, per_model_pool_policy}, PerModel),
    persistent_term:put(
        {?MODULE, max_request_body_bytes},
        app_env(max_request_body_bytes, 33554432)
    ),
    persistent_term:put(
        {?MODULE, max_embedding_inputs},
        app_env(max_embedding_inputs, 256)
    ),
    persistent_term:put(
        {?MODULE, generation_idle_timeout_ms},
        app_env(generation_idle_timeout_ms, 60000)
    ),
    persistent_term:put(
        {?MODULE, prefill_timeout_ms},
        app_env(prefill_timeout_ms, 300000)
    ),
    persistent_term:put(
        {?MODULE, max_total_ms},
        app_env(max_total_ms, 1800000)
    ),
    persistent_term:put({?MODULE, tracing}, app_env(tracing, off)),
    persistent_term:put({?MODULE, max_messages}, app_env(max_messages, 1024)),
    persistent_term:put({?MODULE, max_tools}, app_env(max_tools, 128)),
    persistent_term:put({?MODULE, cors}, app_env(cors, off)),
    persistent_term:put(
        {?MODULE, request_id_header},
        app_env(request_id_header, <<"x-request-id">>)
    ),
    persistent_term:put({?MODULE, auto_pull}, app_env(auto_pull, false)),
    persistent_term:put(
        {?MODULE, keep_alive_default_ms},
        app_env(keep_alive_default_ms, 300000)
    ),
    persistent_term:put(
        {?MODULE, anthropic_api_keys}, app_env(anthropic_api_keys, [])
    ),
    persistent_term:put(
        {?MODULE, anthropic_retry_after_seconds},
        app_env(anthropic_retry_after_seconds, 5)
    ),
    persistent_term:put(
        {?MODULE, tool_call_formats},
        maps:merge(default_tool_call_formats(), app_env(tool_call_formats, #{}))
    ),
    {ok, #state{
        aliases = Aliases,
        load_policy = LoadPolicy,
        pool_policy = PoolPolicy,
        per_model_pool_policy = PerModel
    }}.

handle_call({ensure_loaded, ModelId, Deadline}, From, S = #state{load_policy = Policy}) ->
    case fast_check(ModelId) of
        ready ->
            {reply, ok, S};
        not_ready when Policy =:= preloaded ->
            {reply, {error, not_preloaded}, S};
        not_ready when Policy =:= reject ->
            {reply, {error, not_loaded}, S};
        not_ready when Policy =:= on_demand ->
            S1 = await_loader(ModelId, From, Deadline, S),
            {noreply, S1}
    end;
handle_call({ensure_loaded_async, ModelId, Caller}, _From, S = #state{load_policy = Policy}) ->
    case fast_check(ModelId) of
        ready ->
            Caller ! {erllama_load_done, ModelId, ok},
            {reply, ok, S};
        not_ready when Policy =:= preloaded ->
            {reply, {error, not_preloaded}, S};
        not_ready when Policy =:= reject ->
            {reply, {error, not_loaded}, S};
        not_ready when Policy =:= on_demand ->
            S1 = subscribe_loader(ModelId, Caller, S),
            {reply, ok, S1}
    end;
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({set_aliases, Map}, S) ->
    persistent_term:put({?MODULE, aliases}, Map),
    {noreply, S#state{aliases = Map}};
handle_cast(_, S) ->
    {noreply, S}.

handle_info({'DOWN', MonRef, process, Pid, _Reason}, S = #state{loaders = L}) ->
    %% A loader exited. Drop its entry; the loader is responsible for
    %% replying to its waiters before exit.
    L1 = maps:filter(fun(_, {P, M}) -> P =/= Pid orelse M =/= MonRef end, L),
    {noreply, S#state{loaders = L1}};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

app_env(Key, Default) ->
    application:get_env(?APP, Key, Default).

fast_check(ModelId) ->
    %% erllama:model_info/1 returns the map directly when loaded and
    %% crashes (noproc) when the model is not registered. Any status
    %% value means the model is up; a noproc means we still need to
    %% load. We match on `status` presence rather than a closed enum
    %% so future engine state additions (0.2.0 already runs with
    %% `running` alongside idle/prefilling/generating) flow through.
    %% Off-spec returns raise try_clause and are caught alongside
    %% noproc.
    try erllama:model_info(ModelId) of
        #{status := _} -> ready
    catch
        _:_ -> not_ready
    end.

await_loader(ModelId, From, Deadline, S = #state{loaders = L}) ->
    case maps:find(ModelId, L) of
        {ok, {Pid, _Mon}} ->
            erllama_server_loader:await(Pid, From, Deadline),
            S;
        error ->
            {ok, Pid} = erllama_server_loaders_sup:start_loader(ModelId),
            Mon = monitor(process, Pid),
            erllama_server_loader:await(Pid, From, Deadline),
            S#state{loaders = L#{ModelId => {Pid, Mon}}}
    end.

subscribe_loader(ModelId, Caller, S = #state{loaders = L}) ->
    case maps:find(ModelId, L) of
        {ok, {Pid, _Mon}} ->
            erllama_server_loader:subscribe(Pid, Caller),
            S;
        error ->
            {ok, Pid} = erllama_server_loaders_sup:start_loader(ModelId),
            Mon = monitor(process, Pid),
            erllama_server_loader:subscribe(Pid, Caller),
            S#state{loaders = L#{ModelId => {Pid, Mon}}}
    end.
