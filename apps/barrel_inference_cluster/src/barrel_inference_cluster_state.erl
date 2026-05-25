%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_state).
-moduledoc """
Cluster membership + routing state for the facade.

When `enabled`, this gen_server advertises the local node in the mycelium service
registry (the `inference_node` service, metadata = loaded models + per-model load +
zone + cold-load policy), subscribes to BOTH peer events (`mycelium:subscribe/0`)
and service events (`mycelium:subscribe_services/0`), and on a timer refreshes its
own advertisement and the peer-metadata cache (plus per-peer SRTT). When disabled
or run without mycelium it degrades to a pure local passthrough: the only candidate
is the local node.

It owns three public ETS tables read directly by the facade on the hot path:
- `peers` — `Node => metadata map` gossiped via the registry.
- `refs` — `Ref => {Node, CallerPid, MonRef}` for remote streaming requests, so
  `cancel/1` can route and a caller's exit reaps its refs (the facade never sees
  `barrel_inference_done`, so the monitored caller is the lifecycle signal).
- `sessions` — `SessionId => {Node, ExpiresAtMs}` sticky affinity.

Static config (zone, cold-load policy) is published to `persistent_term` so the
facade can build candidates without a gen_server round-trip.
""".

-behaviour(gen_server).

-include("barrel_inference_cluster.hrl").
%% #service_entry{} from mycelium:lookup/1. Only compiled under the `cluster`
%% profile, where mycelium is a dependency.
-include_lib("mycelium/include/mycelium.hrl").

-export([start_link/0]).
-export([
    candidates/1,
    affinity_home/1,
    record_affinity/2,
    track_ref/3,
    lookup_ref/1,
    untrack_ref/1,
    node_snapshot/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Exported for unit tests.
-export([local_models_meta/0, peer_locality/3]).

-define(PEERS, barrel_inference_cluster_peers).
-define(REFS, barrel_inference_cluster_refs).
-define(SESSIONS, barrel_inference_cluster_sessions).
-define(PT_CONFIG, {?MODULE, config}).

-type meta() :: #{
    zone => binary() | undefined,
    models => #{binary() => #{load => float()}},
    allow_cold_load => boolean(),
    srtt => non_neg_integer() | undefined
}.

-record(state, {
    enabled = false :: boolean(),
    service = inference_node :: atom(),
    refresh_ms = 2000 :: pos_integer(),
    session_ttl_ms = 600000 :: pos_integer(),
    ref_ttl_ms = 1800000 :: pos_integer(),
    refresh_timer :: reference() | undefined,
    sweep_timer :: reference() | undefined
}).
-type state() :: #state{}.

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Build the routing candidate set for a model: the local node plus cached peers.".
-spec candidates(binary()) -> [#candidate{}].
candidates(Model) when is_binary(Model) ->
    #{zone := OwnZone, allow_cold_load := OwnCold} = config(),
    LocalModels = safe_local_models_meta(),
    Local = #candidate{
        node = node(),
        hosts_model = maps:is_key(Model, LocalModels),
        load = model_load(Model, LocalModels),
        locality = 1.0,
        allow_cold_load = OwnCold
    },
    Peers = [
        peer_candidate(Node, Meta, Model, OwnZone)
     || {Node, Meta} <- peer_list(), Node =/= node()
    ],
    [Local | Peers].

-doc "Sticky session home, if recorded and not expired.".
-spec affinity_home(binary()) -> {ok, node()} | none.
affinity_home(SessionId) when is_binary(SessionId) ->
    case ets_lookup(?SESSIONS, SessionId) of
        {ok, {Node, ExpiresAt}} ->
            case now_ms() < ExpiresAt of
                true -> {ok, Node};
                false -> none
            end;
        error ->
            none
    end.

-doc "Pin a session to the node that served it.".
-spec record_affinity(binary(), node()) -> ok.
record_affinity(SessionId, Node) when is_binary(SessionId), is_atom(Node) ->
    gen_server:cast(?MODULE, {record_affinity, SessionId, Node}).

-doc """
Track a remote streaming request so `cancel/1` can route to its home node and the
caller's exit reaps it. Monitors `CallerPid`.
""".
-spec track_ref(reference(), node(), pid()) -> ok.
track_ref(Ref, Node, CallerPid) when is_reference(Ref), is_atom(Node), is_pid(CallerPid) ->
    gen_server:cast(?MODULE, {track_ref, Ref, Node, CallerPid}).

-spec lookup_ref(reference()) -> {ok, node()} | error.
lookup_ref(Ref) when is_reference(Ref) ->
    case ets_lookup(?REFS, Ref) of
        {ok, {Node, _CallerPid, _Mon}} -> {ok, Node};
        error -> error
    end.

-spec untrack_ref(reference()) -> ok.
untrack_ref(Ref) when is_reference(Ref) ->
    gen_server:cast(?MODULE, {untrack_ref, Ref}).

-doc "Snapshot of this node's view of the cluster (for the CLI/admin).".
-spec node_snapshot() -> map().
node_snapshot() ->
    #{zone := Zone, allow_cold_load := Cold} = config(),
    #{
        node => node(),
        zone => Zone,
        allow_cold_load => Cold,
        models => safe_local_models_meta(),
        peers => maps:from_list(peer_list())
    }.

%% =============================================================================
%% gen_server
%% =============================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    _ = ets_new(?PEERS),
    _ = ets_new(?REFS),
    _ = ets_new(?SESSIONS),
    Enabled = cfg(enabled, false),
    persistent_term:put(?PT_CONFIG, #{
        zone => cfg(zone, undefined),
        allow_cold_load => cfg(allow_cold_load, true)
    }),
    St = #state{
        enabled = Enabled,
        service = cfg(service_name, inference_node),
        refresh_ms = cfg(metadata_refresh_ms, 2000),
        session_ttl_ms = cfg(session_ttl_ms, 600000),
        ref_ttl_ms = cfg(ref_ttl_ms, 1800000)
    },
    St1 = maybe_join_overlay(St),
    {ok, arm_timers(St1)}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({record_affinity, SessionId, Node}, St) ->
    Expires = now_ms() + St#state.session_ttl_ms,
    true = ets:insert(?SESSIONS, {SessionId, {Node, Expires}}),
    {noreply, St};
handle_cast({track_ref, Ref, Node, CallerPid}, St) ->
    Mon = erlang:monitor(process, CallerPid),
    true = ets:insert(?REFS, {Ref, {Node, CallerPid, Mon}}),
    {noreply, St};
handle_cast({untrack_ref, Ref}, St) ->
    drop_ref(Ref),
    {noreply, St};
handle_cast(_Msg, St) ->
    {noreply, St}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(refresh, St) ->
    St1 = refresh(St),
    {noreply, arm_refresh(St1)};
handle_info(sweep, St) ->
    sweep_sessions(),
    {noreply, arm_sweep(St)};
handle_info({mycelium_event, {peer_down, Node, _Reason}}, St) ->
    ets:delete(?PEERS, Node),
    fail_node_refs(Node),
    {noreply, St};
handle_info({mycelium_event, _Other}, St) ->
    {noreply, St};
handle_info({mycelium_service_event, _Event}, St) ->
    %% Service registry changed; pull a fresh view rather than apply deltas.
    {noreply, refresh_peers(St)};
handle_info({'DOWN', _Mon, process, CallerPid, _Reason}, St) ->
    drop_caller_refs(CallerPid),
    {noreply, St};
handle_info(_Msg, St) ->
    {noreply, St}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #state{enabled = true, service = Service}) ->
    _ =
        try
            mycelium:unregister_service(Service)
        catch
            _:_ -> ok
        end,
    ok;
terminate(_Reason, _St) ->
    ok.

%% =============================================================================
%% overlay integration (enabled mode)
%% =============================================================================

maybe_join_overlay(#state{enabled = false} = St) ->
    St;
maybe_join_overlay(#state{enabled = true, service = Service} = St) ->
    %% mycelium is an application dependency, so it is already started in a
    %% clustered release. Guard anyway: a failure degrades to local-only.
    try
        ok = mycelium:subscribe(),
        ok = mycelium:subscribe_services(),
        ok = mycelium:register_service(Service, build_self_meta()),
        St
    catch
        Class:Reason ->
            logger:warning(
                "[barrel_inference_cluster] overlay join failed (~p:~p); "
                "running local-only",
                [Class, Reason]
            ),
            St#state{enabled = false}
    end.

refresh(#state{enabled = false} = St) ->
    St;
refresh(St) ->
    _ =
        try
            mycelium:register_service(St#state.service, build_self_meta())
        catch
            _:_ -> ok
        end,
    refresh_peers(St).

refresh_peers(#state{enabled = false} = St) ->
    St;
refresh_peers(#state{service = Service} = St) ->
    try mycelium:lookup(Service) of
        {ok, Entries} ->
            Seen = apply_entries(Entries),
            prune_peers(Seen),
            barrel_inference_cluster_metrics:set_peers(length(Seen)),
            St;
        _ ->
            St
    catch
        _:_ -> St
    end.

%% @private Upsert each remote service entry into the peer cache, returning the
%% set of live peer nodes for pruning.
apply_entries(Entries) ->
    lists:foldl(
        fun
            (#service_entry{node = Node, meta = Meta}, Acc) when Node =/= node() ->
                Srtt = srtt(Node),
                true = ets:insert(?PEERS, {Node, Meta#{srtt => Srtt}}),
                [Node | Acc];
            (_Entry, Acc) ->
                Acc
        end,
        [],
        Entries
    ).

%% @private Drop cached peers no longer present in the registry.
prune_peers(Seen) ->
    Cached = [N || {N, _} <- ets:tab2list(?PEERS)],
    [ets:delete(?PEERS, N) || N <- Cached, not lists:member(N, Seen)],
    ok.

srtt(Node) ->
    try mycelium_path_stats:srtt(Node) of
        {ok, Ms} -> Ms;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

-spec build_self_meta() -> meta().
build_self_meta() ->
    #{zone := Zone, allow_cold_load := Cold} = config(),
    #{
        zone => Zone,
        allow_cold_load => Cold,
        models => safe_local_models_meta()
    }.

%% =============================================================================
%% candidate / metadata helpers
%% =============================================================================

%% @private Per-model load map for the local node, from runtime introspection.
-spec local_models_meta() -> #{binary() => #{load => float()}}.
local_models_meta() ->
    lists:foldl(
        fun(Info, Acc) ->
            Id = model_id(Info),
            Acc#{Id => #{load => load_fraction(Info)}}
        end,
        #{},
        barrel_inference:list_models()
    ).

safe_local_models_meta() ->
    try
        local_models_meta()
    catch
        _:_ -> #{}
    end.

model_id(Info) ->
    case maps:get(id, Info, undefined) of
        undefined -> maps:get(model_id, Info, <<>>);
        Id -> Id
    end.

load_fraction(Info) ->
    Avail = maps:get(available_seqs, Info, 0),
    Max = maps:get(n_seq_max, Info, 1),
    case Max of
        0 -> 0.0;
        _ -> Avail / Max
    end.

model_load(Model, Models) ->
    case maps:get(Model, Models, undefined) of
        undefined -> 0.0;
        #{load := L} -> L
    end.

peer_candidate(Node, Meta, Model, OwnZone) ->
    Models = maps:get(models, Meta, #{}),
    #candidate{
        node = Node,
        hosts_model = maps:is_key(Model, Models),
        load = model_load(Model, Models),
        locality = peer_locality(
            maps:get(zone, Meta, undefined), OwnZone, maps:get(srtt, Meta, undefined)
        ),
        allow_cold_load = maps:get(allow_cold_load, Meta, false)
    }.

-doc "Locality score for a peer. Exported for unit tests.".
-spec peer_locality(binary() | undefined, binary() | undefined, non_neg_integer() | undefined) ->
    float().
peer_locality(PeerZone, OwnZone, Srtt) ->
    case OwnZone =/= undefined andalso PeerZone =:= OwnZone of
        true -> 0.8;
        false -> srtt_locality(Srtt)
    end.

srtt_locality(undefined) -> 0.3;
srtt_locality(Ms) when Ms =< 1 -> 0.6;
srtt_locality(Ms) when Ms =< 10 -> 0.5;
srtt_locality(Ms) when Ms =< 50 -> 0.4;
srtt_locality(_Ms) -> 0.2.

%% =============================================================================
%% ref / session bookkeeping
%% =============================================================================

fail_node_refs(Node) ->
    Refs = [Ref || {Ref, {N, _Pid, _Mon}} <- ets:tab2list(?REFS), N =:= Node],
    [drop_ref(Ref) || Ref <- Refs],
    %% Drop sticky entries pinned to the dead node so the next turn re-places.
    Stale = [Sid || {Sid, {N, _Exp}} <- ets:tab2list(?SESSIONS), N =:= Node],
    [ets:delete(?SESSIONS, Sid) || Sid <- Stale],
    ok.

drop_caller_refs(CallerPid) ->
    Refs = [Ref || {Ref, {_N, Pid, _Mon}} <- ets:tab2list(?REFS), Pid =:= CallerPid],
    [ets:delete(?REFS, Ref) || Ref <- Refs],
    ok.

drop_ref(Ref) ->
    case ets_lookup(?REFS, Ref) of
        {ok, {_Node, _Pid, Mon}} ->
            _ = erlang:demonitor(Mon, [flush]),
            ets:delete(?REFS, Ref);
        error ->
            ok
    end,
    ok.

sweep_sessions() ->
    Now = now_ms(),
    Expired = [Sid || {Sid, {_N, Exp}} <- ets:tab2list(?SESSIONS), Exp =< Now],
    [ets:delete(?SESSIONS, Sid) || Sid <- Expired],
    ok.

%% =============================================================================
%% misc
%% =============================================================================

peer_list() ->
    ets:tab2list(?PEERS).

config() ->
    persistent_term:get(?PT_CONFIG, #{zone => undefined, allow_cold_load => true}).

cfg(Key, Default) ->
    application:get_env(barrel_inference_cluster, Key, Default).

ets_new(Name) ->
    ets:new(Name, [named_table, public, set, {read_concurrency, true}]).

ets_lookup(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> error
    end.

arm_timers(St) ->
    arm_sweep(arm_refresh(St)).

arm_refresh(#state{enabled = false} = St) ->
    St;
arm_refresh(#state{refresh_ms = Ms} = St) ->
    St#state{refresh_timer = erlang:send_after(Ms, self(), refresh)}.

arm_sweep(#state{session_ttl_ms = Ttl} = St) ->
    %% Sweep at a fraction of the session TTL (bounded).
    Every = max(1000, Ttl div 10),
    St#state{sweep_timer = erlang:send_after(Every, self(), sweep)}.

now_ms() ->
    erlang:system_time(millisecond).
