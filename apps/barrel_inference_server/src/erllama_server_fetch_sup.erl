%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_fetch_sup).
-moduledoc """
`simple_one_for_one` supervisor for transient
`erllama_server_fetch_worker` processes. Workers are spawned by
`erllama_server_fetch_srv` once per unique in-flight spec and exit
normally on completion.
""".
-behaviour(supervisor).

-export([start_link/0, start_worker/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_worker(erllama_server_fetch_resolvers:parsed(), map(), pid()) ->
    {ok, pid()} | {error, term()}.
start_worker(Parsed, Opts, SrvPid) ->
    supervisor:start_child(?SERVER, [Parsed, Opts, SrvPid]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 30},
    Child = #{
        id => erllama_server_fetch_worker,
        start => {erllama_server_fetch_worker, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [erllama_server_fetch_worker]
    },
    {ok, {SupFlags, [Child]}}.
