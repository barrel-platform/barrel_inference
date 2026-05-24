%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_pull_sup).
-moduledoc """
`simple_one_for_one` supervisor for transient `barrel_inference_server_pull`
coordinators. One coordinator per pull, started via `start_pull/5`. The
coordinator owns the fetch and manifest persistence and outlives the HTTP
handler that requested the pull, so a completed download always registers.
""".
-behaviour(supervisor).

-export([start_link/0, start_pull/5]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_pull(binary(), binary(), binary(), map(), [pid()]) ->
    {ok, pid()} | {error, term()}.
start_pull(Spec, Name, Tag, Overrides, Subscribers) ->
    supervisor:start_child(?SERVER, [Spec, Name, Tag, Overrides, Subscribers]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 30},
    Child = #{
        id => barrel_inference_server_pull,
        start => {barrel_inference_server_pull, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [barrel_inference_server_pull]
    },
    {ok, {SupFlags, [Child]}}.
