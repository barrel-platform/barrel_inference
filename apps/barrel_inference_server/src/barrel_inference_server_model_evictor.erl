%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_model_evictor).
-moduledoc """
Server-side implementation of `barrel_inference_model_evictor`.

Wired into the engine scheduler via `scheduler.model_evictor`. When the
scheduler cannot relieve sustained memory pressure through cache
eviction, it calls `evict_one/0`, which unloads the least-recently-active
idle model.

Candidates come from `barrel_inference_server_memory:idle_models/0`
(least-recently-active first). Each is unloaded via the keepalive
`unload_idle_sync/1`, which re-checks `active = 0` atomically inside the
keepalive gen_server - so a model whose request started after the
snapshot returns `busy` and is skipped, never unloaded mid-request. The
walk stops at the first model actually unloaded.
""".

-behaviour(barrel_inference_model_evictor).

-export([evict_one/0]).

-spec evict_one() -> {unloaded, binary()} | none.
evict_one() ->
    try_evict(barrel_inference_server_memory:idle_models()).

try_evict([]) ->
    none;
try_evict([{ModelId, _Ms} | Rest]) ->
    case barrel_inference_server_keepalive:unload_idle_sync(ModelId) of
        ok ->
            _ = barrel_inference_server_memory:wait_unloaded(ModelId),
            {unloaded, ModelId};
        busy ->
            try_evict(Rest)
    end.
