%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_router).
-moduledoc """
Pure replica-selection logic for the cluster facade.

Given the live candidate nodes for a model and the request's routing options,
decide whether to serve `{local}`, route `{remote, Node}`, or report
`{error, no_target}` (no node can serve or cold-load it; the caller then falls
back to the local runtime).

The decision is a three-signal cascade — **affinity → locality → load** — so a
session sticks to the node that warmed its KV cache, new traffic spreads to the
nearest least-loaded replica, and overflow spills to a cold-load target:

1. **Sticky affinity.** If the session's recorded home is still a free replica,
   use it (KV-cache reuse is the biggest agent-serving latency lever).
2. **Score the free replicas.** `score = Wload*load + Wlocality*locality`. The
   weights come from the policy preset (or a custom map). Highest score wins; a
   deterministic node-id tiebreak keeps every node in the cluster in agreement.
3. **Spill.** No free replica ⇒ score the nodes allowed to cold-load the model.
   None ⇒ `{error, no_target}`.

This module is side-effect free: `barrel_inference_cluster_state` gathers the
candidates and the affinity home, and records the placement after `route/2`
returns. That keeps the policy unit-testable with synthetic inputs.
""".

-include("barrel_inference_cluster.hrl").

-export([route/2]).

%% Exported for unit tests.
-export([score/3, weights/1]).

-type policy() ::
    cache_affinity
    | least_load
    | locality
    | round_robin
    | #{load => float(), locality => float()}.

-type opts() :: #{
    local_node := node(),
    affinity_home => node() | undefined,
    policy => policy(),
    rr_seq => non_neg_integer()
}.

-type decision() :: {local} | {remote, node()} | {error, no_target}.
-type candidate() :: #candidate{}.

-export_type([policy/0, opts/0, decision/0, candidate/0]).

-doc """
Choose where to serve a request given the model's candidate nodes.

`Candidates` describe every live node (including the local one). `Opts` carries
`local_node` (required), the session's `affinity_home` (or `undefined`), the
routing `policy`, and a `rr_seq` rotation counter used only by `round_robin`.
""".
-spec route([#candidate{}], opts()) -> decision().
route(Candidates, Opts) ->
    Local = maps:get(local_node, Opts),
    case choose(Candidates, Opts) of
        {ok, Local} -> {local};
        {ok, Node} -> {remote, Node};
        none -> {error, no_target}
    end.

%% @private
-spec choose([#candidate{}], opts()) -> {ok, node()} | none.
choose(Candidates, Opts) ->
    Replicas = free_replicas(Candidates),
    case sticky(maps:get(affinity_home, Opts, undefined), Replicas) of
        {ok, Node} ->
            {ok, Node};
        none ->
            case Replicas of
                [] -> spill(Candidates, Opts);
                _ -> {ok, rank(Replicas, Opts)}
            end
    end.

%% @private Nodes that host the model and still have admission headroom.
free_replicas(Candidates) ->
    [C || C <- Candidates, C#candidate.hosts_model, C#candidate.load > 0.0].

%% @private Honour a recorded session home only while it is a free replica.
sticky(undefined, _Replicas) ->
    none;
sticky(Home, Replicas) ->
    case lists:keymember(Home, #candidate.node, Replicas) of
        true -> {ok, Home};
        false -> none
    end.

%% @private No free replica: pick a cold-load target, if any node allows it.
spill(Candidates, Opts) ->
    case [C || C <- Candidates, C#candidate.allow_cold_load] of
        [] -> none;
        Targets -> {ok, rank(Targets, Opts)}
    end.

%% @private Best node under the policy. `round_robin` rotates on `rr_seq`;
%% every other policy scores and takes the max with a deterministic tiebreak.
-spec rank([#candidate{}], opts()) -> node().
rank(Candidates, Opts) ->
    case maps:get(policy, Opts, cache_affinity) of
        round_robin ->
            Nodes = lists:sort([C#candidate.node || C <- Candidates]),
            Seq = maps:get(rr_seq, Opts, 0),
            lists:nth((Seq rem length(Nodes)) + 1, Nodes);
        Policy ->
            {Wl, Wp} = weights(Policy),
            best_by_score(Candidates, Wl, Wp)
    end.

%% @private Highest score wins; on a tie the smallest node() wins so every
%% node in the cluster reaches the same placement for the same inputs.
best_by_score(Candidates, Wl, Wp) ->
    Scored = [{score(C, Wl, Wp), C#candidate.node} || C <- Candidates],
    Better = fun({S1, N1}, {S2, N2}) ->
        S1 > S2 orelse (S1 =:= S2 andalso N1 =< N2)
    end,
    [{_, Node} | _] = lists:sort(Better, Scored),
    Node.

-doc "Weighted replica score. Exported for unit tests.".
-spec score(#candidate{}, float(), float()) -> float().
score(#candidate{load = Load, locality = Loc}, Wl, Wp) ->
    Wl * Load + Wp * Loc.

-doc "Resolve a policy preset to `{LoadWeight, LocalityWeight}`. Exported for unit tests.".
-spec weights(policy()) -> {float(), float()}.
weights(cache_affinity) -> {0.2, 0.3};
weights(least_load) -> {1.0, 0.1};
weights(locality) -> {0.2, 1.0};
weights(round_robin) -> {1.0, 0.0};
weights(M) when is_map(M) -> {maps:get(load, M, 0.2), maps:get(locality, M, 0.3)}.
