%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_state_SUITE).
-moduledoc "Unit tests for cluster state in local (disabled) mode — no mycelium.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("barrel_inference_cluster.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    candidates_local_only/1,
    candidates_includes_peers/1,
    affinity_record_lookup/1,
    affinity_expired/1,
    ref_track_lookup_untrack/1,
    ref_reaped_on_caller_down/1,
    peer_locality_scores/1
]).

-define(M, barrel_inference_cluster_state).

all() ->
    [
        candidates_local_only,
        candidates_includes_peers,
        affinity_record_lookup,
        affinity_expired,
        ref_track_lookup_untrack,
        ref_reaped_on_caller_down,
        peer_locality_scores
    ].

init_per_suite(Config) ->
    application:set_env(barrel_inference_cluster, enabled, false),
    application:set_env(barrel_inference_cluster, zone, <<"dc1">>),
    {ok, Pid} = ?M:start_link(),
    %% start_link links to CT's transient config process; unlink so the server
    %% (and its ETS tables) survive across the per-testcase processes.
    true = unlink(Pid),
    [{state_pid, Pid} | Config].

end_per_suite(Config) ->
    Pid = proplists:get_value(state_pid, Config),
    gen_server:stop(Pid),
    ok.

init_per_testcase(_Case, Config) ->
    ets:delete_all_objects(barrel_inference_cluster_peers),
    ets:delete_all_objects(barrel_inference_cluster_refs),
    ets:delete_all_objects(barrel_inference_cluster_sessions),
    Config.

%% Flush queued casts by forcing a synchronous round-trip.
sync() ->
    _ = gen_server:call(?M, sync),
    ok.

%% --- cases -----------------------------------------------------------------

candidates_local_only(_Config) ->
    [C] = ?M:candidates(<<"m">>),
    ?assertEqual(node(), C#candidate.node),
    ?assertEqual(1.0, C#candidate.locality),
    %% No runtime models loaded in the test VM.
    ?assertEqual(false, C#candidate.hosts_model),
    ?assertEqual(true, C#candidate.allow_cold_load).

candidates_includes_peers(_Config) ->
    Peer = 'peer@h',
    Meta = #{
        zone => <<"dc1">>,
        allow_cold_load => false,
        models => #{<<"m">> => #{load => 0.5}},
        srtt => 2
    },
    true = ets:insert(barrel_inference_cluster_peers, {Peer, Meta}),
    Cands = ?M:candidates(<<"m">>),
    {value, P} = lists:search(fun(C) -> C#candidate.node =:= Peer end, Cands),
    ?assertEqual(true, P#candidate.hosts_model),
    ?assertEqual(0.5, P#candidate.load),
    %% same zone as own (dc1) => 0.8
    ?assertEqual(0.8, P#candidate.locality),
    ?assertEqual(false, P#candidate.allow_cold_load),
    %% model not hosted by peer => hosts_model false
    Cands2 = ?M:candidates(<<"other">>),
    {value, P2} = lists:search(fun(C) -> C#candidate.node =:= Peer end, Cands2),
    ?assertEqual(false, P2#candidate.hosts_model).

affinity_record_lookup(_Config) ->
    ?assertEqual(none, ?M:affinity_home(<<"s1">>)),
    ok = ?M:record_affinity(<<"s1">>, 'home@h'),
    sync(),
    ?assertEqual({ok, 'home@h'}, ?M:affinity_home(<<"s1">>)).

affinity_expired(_Config) ->
    Past = erlang:system_time(millisecond) - 1000,
    true = ets:insert(barrel_inference_cluster_sessions, {<<"s2">>, {'n@h', Past}}),
    ?assertEqual(none, ?M:affinity_home(<<"s2">>)).

ref_track_lookup_untrack(_Config) ->
    Caller = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Ref = make_ref(),
    ok = ?M:track_ref(Ref, 'rnode@h', Caller),
    sync(),
    ?assertEqual({ok, 'rnode@h'}, ?M:lookup_ref(Ref)),
    ok = ?M:untrack_ref(Ref),
    sync(),
    ?assertEqual(error, ?M:lookup_ref(Ref)),
    Caller ! stop.

ref_reaped_on_caller_down(_Config) ->
    Caller = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Ref = make_ref(),
    ok = ?M:track_ref(Ref, 'rnode@h', Caller),
    sync(),
    ?assertEqual({ok, 'rnode@h'}, ?M:lookup_ref(Ref)),
    exit(Caller, kill),
    ?assertEqual(ok, wait_until(fun() -> ?M:lookup_ref(Ref) =:= error end, 2000)).

peer_locality_scores(_Config) ->
    %% zone match wins regardless of srtt
    ?assertEqual(0.8, ?M:peer_locality(<<"dc1">>, <<"dc1">>, 999)),
    %% no zone match: srtt buckets
    ?assertEqual(0.6, ?M:peer_locality(<<"dc2">>, <<"dc1">>, 1)),
    ?assertEqual(0.4, ?M:peer_locality(<<"dc2">>, <<"dc1">>, 50)),
    ?assertEqual(0.2, ?M:peer_locality(<<"dc2">>, <<"dc1">>, 500)),
    %% unknown own zone never matches
    ?assertEqual(0.3, ?M:peer_locality(<<"dc1">>, undefined, undefined)).

%% --- helpers ---------------------------------------------------------------

wait_until(_Fun, Left) when Left =< 0 ->
    timeout;
wait_until(Fun, Left) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_until(Fun, Left - 25)
    end.
