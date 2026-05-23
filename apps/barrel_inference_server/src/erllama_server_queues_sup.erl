-module(erllama_server_queues_sup).
-behaviour(supervisor).

-export([start_link/0, ensure_queue/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Lazily create the queue gen_server for a model the first time it is
%% needed. Idempotent: if the queue already exists, returns its pid.
-spec ensure_queue(binary()) -> {ok, pid()}.
ensure_queue(ModelId) when is_binary(ModelId) ->
    case erllama_server_registry:whereis_name({queue, ModelId}) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            case supervisor:start_child(?MODULE, [ModelId]) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid}
            end
    end.

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 5, period => 30},
    Child = #{
        id => queue,
        start => {erllama_server_queue, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [Child]}}.
