%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_app).
-moduledoc """
Application entry point for the Barrel Inference cluster facade.

The supervision tree is started unconditionally; the overlay transport
(mycelium) and remote routing are gated by the `enabled` env key, wired in
`barrel_inference_cluster_state` so a node built with this app can still run
as a pure local passthrough.
""".

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    ok = barrel_inference_cluster_metrics:init(),
    barrel_inference_cluster_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
