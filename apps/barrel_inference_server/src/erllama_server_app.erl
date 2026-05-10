-module(erllama_server_app).
-behaviour(application).

-export([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
    ok = erllama_server_metrics:init(),
    erllama_server_sup:start_link().

%% Application is asked to stop. Refuse new connections, then wait
%% (bounded) for in-flight streams to drain, then stop the listener.
%% Past the drain budget, cowboy:stop_listener closes stragglers.
prep_stop(State) ->
    Ref = erllama_server_http,
    _ = (catch ranch:suspend_listener(Ref)),
    DeadlineMs =
        erlang:monotonic_time(millisecond) +
            application:get_env(erllama_server, shutdown_timeout_ms, 5000),
    drain(Ref, DeadlineMs),
    _ = (catch cowboy:stop_listener(Ref)),
    State.

drain(Ref, DeadlineMs) ->
    Conns = (catch ranch:info(Ref)),
    Active = active_conns(Conns),
    case Active of
        0 ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= DeadlineMs of
                true ->
                    ok;
                false ->
                    timer:sleep(50),
                    drain(Ref, DeadlineMs)
            end
    end.

active_conns(L) when is_list(L) ->
    proplists:get_value(active_connections, L, 0);
active_conns(_) ->
    0.

stop(_State) ->
    ok.
