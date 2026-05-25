%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_facade_SUITE).
-moduledoc """
Facade routing tests. Exercises `barrel_inference_cluster:route/2` (which wires the
state candidate set into the router) against synthetic peers — no runtime and no
erpc dispatch (that is covered by the gated overlay suite).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    route_local_no_peers/1,
    route_remote_to_hosting_peer/1,
    route_sticky_home/1,
    route_spill_local_cold/1,
    node_snapshot_shape/1
]).

-define(PEERS, barrel_inference_cluster_peers).

all() ->
    [
        route_local_no_peers,
        route_remote_to_hosting_peer,
        route_sticky_home,
        route_spill_local_cold,
        node_snapshot_shape
    ].

init_per_suite(Config) ->
    application:set_env(barrel_inference_cluster, enabled, false),
    application:set_env(barrel_inference_cluster, replica_policy, cache_affinity),
    {ok, Pid} = barrel_inference_cluster_state:start_link(),
    true = unlink(Pid),
    [{state_pid, Pid} | Config].

end_per_suite(Config) ->
    gen_server:stop(proplists:get_value(state_pid, Config)),
    ok.

init_per_testcase(_Case, Config) ->
    ets:delete_all_objects(?PEERS),
    Config.

peer(Node, Meta) ->
    true = ets:insert(?PEERS, {Node, Meta}).

%% --- cases -----------------------------------------------------------------

route_local_no_peers(_Config) ->
    %% Local hosts nothing, but may cold-load, and there are no peers.
    ?assertEqual({local}, barrel_inference_cluster:route(<<"m">>, undefined)).

route_remote_to_hosting_peer(_Config) ->
    peer('peer@h', #{
        zone => undefined,
        allow_cold_load => false,
        models => #{<<"m">> => #{load => 0.5}},
        srtt => 2
    }),
    ?assertEqual({remote, 'peer@h'}, barrel_inference_cluster:route(<<"m">>, undefined)).

route_sticky_home(_Config) ->
    %% Both peers host the model and are free; affinity must pin to peerB even
    %% though peerA has more headroom.
    peer('peerA@h', #{models => #{<<"m">> => #{load => 0.9}}, srtt => 1}),
    peer('peerB@h', #{models => #{<<"m">> => #{load => 0.1}}, srtt => 1}),
    ?assertEqual({remote, 'peerB@h'}, barrel_inference_cluster:route(<<"m">>, 'peerB@h')).

route_spill_local_cold(_Config) ->
    %% No node hosts the model; the peer cannot cold-load, the local node can.
    peer('peer@h', #{allow_cold_load => false, models => #{}, srtt => 1}),
    ?assertEqual({local}, barrel_inference_cluster:route(<<"m">>, undefined)).

node_snapshot_shape(_Config) ->
    Snap = barrel_inference_cluster:node_snapshot(),
    ?assertEqual(node(), maps:get(node, Snap)),
    ?assert(is_map(maps:get(models, Snap))),
    ?assert(is_map(maps:get(peers, Snap))).
