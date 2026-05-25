%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_strategy).
-moduledoc """
Behaviour for cluster routing strategies.

v1 ships one strategy, `barrel_inference_cluster_strategy_cache_affinity`. The
behaviour is the seam for the gated follow-ons named in the ROADMAP — cross-node
speculative decoding (`barrel_inference:verify/4`) and pipeline parallelism
(`barrel_inference:forward_partial/3`) — which register additional strategies and
are selected via `applicable/1`.

- `name/0` — the policy atom this strategy implements.
- `applicable/1` — whether the strategy can handle a given request (so the facade
  can pick among several; v1's single strategy always returns `true`).
- `route/2` — pick a target from the live candidates, delegating the scoring to
  `barrel_inference_cluster_router`.
""".

-callback name() -> atom().
-callback applicable(Request :: map()) -> boolean().
-callback route(Request :: map(), Candidates :: [barrel_inference_cluster_router:candidate()]) ->
    barrel_inference_cluster_router:decision().
