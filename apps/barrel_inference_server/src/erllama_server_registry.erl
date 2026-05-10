%%% via_module backed by a public ETS table.
%%%
%%% Lets us register processes under arbitrary terms, e.g.
%%% `{via, erllama_server_registry, {queue, ModelId}}` for the
%%% per-model queue gen_servers spawned dynamically by
%%% erllama_server_queues_sup.
%%%
%%% The registry is a tiny gen_server whose only job is to own the
%%% ETS table; lookups go straight to ETS in caller context, so the
%%% gen_server is never on the hot path.

-module(erllama_server_registry).
-behaviour(gen_server).

-export([
    start_link/0,
    register_name/2,
    unregister_name/1,
    whereis_name/1,
    send/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, ?MODULE).

%%====================================================================
%% via API
%%====================================================================

-spec register_name(term(), pid()) -> yes | no.
register_name(Name, Pid) when is_pid(Pid) ->
    case ets:insert_new(?TABLE, {Name, Pid, monitor(process, Pid)}) of
        true -> yes;
        false -> no
    end.

-spec unregister_name(term()) -> term().
unregister_name(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, _Pid, MonRef}] ->
            demonitor(MonRef, [flush]),
            ets:delete(?TABLE, Name);
        [] ->
            ok
    end,
    Name.

-spec whereis_name(term()) -> pid() | undefined.
whereis_name(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Pid, _}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        [] ->
            undefined
    end.

-spec send(term(), term()) -> pid().
send(Name, Msg) ->
    case whereis_name(Name) of
        Pid when is_pid(Pid) ->
            Pid ! Msg,
            Pid;
        undefined ->
            error({badarg, {Name, Msg}})
    end.

%%====================================================================
%% gen_server
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #{}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({'DOWN', _MonRef, process, Pid, _Reason}, S) ->
    %% Sweep entries for this pid; ETS doesn't index by pid so we use
    %% a small select. The table is expected to stay small (one entry
    %% per loaded model).
    Entries = ets:match_object(?TABLE, {'_', Pid, '_'}),
    lists:foreach(fun({Name, _, _}) -> ets:delete(?TABLE, Name) end, Entries),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.
