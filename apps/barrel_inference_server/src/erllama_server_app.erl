-module(erllama_server_app).
-behaviour(application).

-export([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
    ok = erllama_server_metrics:init(),
    ok = ensure_model_default_opts(),
    erllama_server_sup:start_link().

%% Bake the default `erllama:load_model/2` options the loader will
%% layer manifest-derived fields on top of. Operators can override
%% the whole map via `application:set_env(erllama_server,
%% model_default_opts, ...)` in `sys.config`.
ensure_model_default_opts() ->
    Existing = application:get_env(erllama_server, model_default_opts, undefined),
    Defaults = #{
        backend => erllama_model_llama,
        tier_srv => erllama_server_disk_cache,
        tier => disk,
        fingerprint_mode => safe,
        ctx_params_hash => binary:copy(<<0>>, 32),
        policy => default_cache_policy()
    },
    Merged =
        case Existing of
            undefined -> Defaults;
            M when is_map(M) -> maps:merge(Defaults, M)
        end,
    application:set_env(erllama_server, model_default_opts, Merged),
    ok.

default_cache_policy() ->
    #{
        min_tokens => 64,
        cold_min_tokens => 128,
        cold_max_tokens => 8192,
        continued_interval => 2048,
        boundary_trim_tokens => 0,
        boundary_align_tokens => 16,
        session_resume_wait_ms => 500
    }.

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
