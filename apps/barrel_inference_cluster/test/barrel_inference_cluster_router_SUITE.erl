%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_router_SUITE).
-moduledoc "Pure unit tests for the cluster replica-selection logic.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("barrel_inference_cluster.hrl").

-export([all/0]).
-export([
    single_local/1,
    empty_candidates/1,
    sticky_home_used/1,
    sticky_home_saturated/1,
    sticky_home_missing_model/1,
    least_load_picks_freest/1,
    locality_prefers_near/1,
    spill_remote_cold_loader/1,
    spill_local_preferred/1,
    spill_none_allowed/1,
    round_robin_rotates/1,
    deterministic_tiebreak/1
]).

all() ->
    [
        single_local,
        empty_candidates,
        sticky_home_used,
        sticky_home_saturated,
        sticky_home_missing_model,
        least_load_picks_freest,
        locality_prefers_near,
        spill_remote_cold_loader,
        spill_local_preferred,
        spill_none_allowed,
        round_robin_rotates,
        deterministic_tiebreak
    ].

%% --- helpers ---------------------------------------------------------------

cand(Node, Hosts, Load, Loc, Cold) ->
    #candidate{
        node = Node,
        hosts_model = Hosts,
        load = Load,
        locality = Loc,
        allow_cold_load = Cold
    }.

route(Cands, Opts) ->
    barrel_inference_cluster_router:route(Cands, Opts).

%% --- cases -----------------------------------------------------------------

single_local(_Config) ->
    C = [cand('a@h', true, 0.5, 1.0, true)],
    ?assertEqual({local}, route(C, #{local_node => 'a@h'})).

empty_candidates(_Config) ->
    ?assertEqual({error, no_target}, route([], #{local_node => 'a@h'})).

sticky_home_used(_Config) ->
    %% Home b@h is a free replica; affinity wins over a@h's better score.
    C = [cand('a@h', true, 0.9, 1.0, true), cand('b@h', true, 0.1, 0.2, true)],
    ?assertEqual(
        {remote, 'b@h'},
        route(C, #{local_node => 'a@h', affinity_home => 'b@h', policy => least_load})
    ).

sticky_home_saturated(_Config) ->
    %% Home b@h is saturated (load 0.0) so it is not a free replica; score a@h.
    C = [cand('a@h', true, 0.8, 1.0, true), cand('b@h', true, 0.0, 1.0, true)],
    ?assertEqual(
        {local},
        route(C, #{local_node => 'a@h', affinity_home => 'b@h', policy => least_load})
    ).

sticky_home_missing_model(_Config) ->
    %% Home b@h does not host the model; fall through to a@h.
    C = [cand('a@h', true, 0.5, 1.0, true), cand('b@h', false, 0.9, 1.0, true)],
    ?assertEqual(
        {local},
        route(C, #{local_node => 'a@h', affinity_home => 'b@h', policy => least_load})
    ).

least_load_picks_freest(_Config) ->
    %% b@h has more free capacity; least_load routes there.
    C = [cand('a@h', true, 0.2, 1.0, true), cand('b@h', true, 0.9, 0.2, true)],
    ?assertEqual({remote, 'b@h'}, route(C, #{local_node => 'a@h', policy => least_load})).

locality_prefers_near(_Config) ->
    %% Local a@h (locality 1.0) beats freer-but-far b@h under the locality policy.
    C = [cand('a@h', true, 0.3, 1.0, true), cand('b@h', true, 0.9, 0.2, true)],
    ?assertEqual({local}, route(C, #{local_node => 'a@h', policy => locality})).

spill_remote_cold_loader(_Config) ->
    %% No node hosts the model; only b@h may cold-load.
    C = [cand('a@h', false, 0.5, 1.0, false), cand('b@h', false, 0.5, 0.2, true)],
    ?assertEqual({remote, 'b@h'}, route(C, #{local_node => 'a@h', policy => least_load})).

spill_local_preferred(_Config) ->
    %% No node hosts the model; both may cold-load; locality policy prefers local.
    C = [cand('a@h', false, 0.5, 1.0, true), cand('b@h', false, 0.9, 0.2, true)],
    ?assertEqual({local}, route(C, #{local_node => 'a@h', policy => locality})).

spill_none_allowed(_Config) ->
    C = [cand('a@h', false, 0.5, 1.0, false), cand('b@h', false, 0.5, 0.2, false)],
    ?assertEqual({error, no_target}, route(C, #{local_node => 'a@h'})).

round_robin_rotates(_Config) ->
    %% Sorted nodes [a,b,c]; rr_seq selects in rotation.
    C = [
        cand('a@h', true, 0.5, 1.0, true),
        cand('b@h', true, 0.5, 1.0, true),
        cand('c@h', true, 0.5, 1.0, true)
    ],
    RR = fun(Seq) -> route(C, #{local_node => 'a@h', policy => round_robin, rr_seq => Seq}) end,
    ?assertEqual({local}, RR(0)),
    ?assertEqual({remote, 'b@h'}, RR(1)),
    ?assertEqual({remote, 'c@h'}, RR(2)),
    ?assertEqual({local}, RR(3)).

deterministic_tiebreak(_Config) ->
    %% Equal score: smallest node id wins, regardless of input order.
    C1 = [cand('a@h', true, 0.5, 0.5, true), cand('b@h', true, 0.5, 0.5, true)],
    C2 = lists:reverse(C1),
    ?assertEqual({local}, route(C1, #{local_node => 'a@h', policy => least_load})),
    ?assertEqual({local}, route(C2, #{local_node => 'a@h', policy => least_load})),
    ?assertEqual({remote, 'a@h'}, route(C1, #{local_node => 'b@h', policy => least_load})),
    ?assertEqual({remote, 'a@h'}, route(C2, #{local_node => 'b@h', policy => least_load})).
