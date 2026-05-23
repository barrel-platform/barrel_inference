-module(barrel_inference_server_loaders_sup).
-behaviour(supervisor).

-export([start_link/0, start_loader/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_loader(binary()) -> {ok, pid()}.
start_loader(ModelId) ->
    supervisor:start_child(?MODULE, [ModelId]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 5, period => 30},
    Child = #{
        id => loader,
        start => {barrel_inference_server_loader, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [Child]}}.
