%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_sup).
-moduledoc """
Root supervisor for the cluster facade.

Children are added as the facade lands: `barrel_inference_cluster_state`
(mycelium registration, peer/metadata caches, ref/session maps) and the
metrics owner. The skeleton starts with no children so the umbrella stays
green before the overlay dependency is introduced.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    Children = [
        #{
            id => barrel_inference_cluster_state,
            start => {barrel_inference_cluster_state, start_link, []},
            type => worker,
            shutdown => 5000
        }
    ],
    {ok, {SupFlags, Children}}.
