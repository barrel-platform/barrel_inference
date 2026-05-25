%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_strategy_cache_affinity).
-moduledoc """
v1 routing strategy: cache-affinity request distribution.

Maps a request map onto `barrel_inference_cluster_router` options and delegates
the affinity → locality → load decision. `applicable/1` is always true, so this
is the default and only strategy until the gated follow-ons land.
""".

-behaviour(barrel_inference_cluster_strategy).

-export([name/0, applicable/1, route/2]).

-spec name() -> cache_affinity.
name() ->
    cache_affinity.

-spec applicable(map()) -> boolean().
applicable(_Request) ->
    true.

-spec route(map(), [barrel_inference_cluster_router:candidate()]) ->
    barrel_inference_cluster_router:decision().
route(Request, Candidates) ->
    Opts = #{
        local_node => maps:get(local_node, Request, node()),
        affinity_home => maps:get(affinity_home, Request, undefined),
        policy => maps:get(policy, Request, cache_affinity),
        rr_seq => maps:get(rr_seq, Request, 0)
    },
    barrel_inference_cluster_router:route(Candidates, Opts).
