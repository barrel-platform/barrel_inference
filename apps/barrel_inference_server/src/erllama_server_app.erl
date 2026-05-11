-module(erllama_server_app).
-behaviour(application).

-export([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
    ok = erllama_server_metrics:init(),
    ok = ensure_model_default_opts(),
    case erllama_server_sup:start_link() of
        {ok, _Sup} = OK ->
            ok = maybe_bootstrap_models(),
            OK;
        E ->
            E
    end.

%% On boot, kick off a background pull for any spec listed in the
%% `bootstrap_models` app env (or the `ERLLAMA_BOOTSTRAP_MODELS` env
%% var, comma-separated). Models that are already in the registry
%% are short-circuited by the fetch cache. Failures are logged but
%% non-fatal so the server still comes up if the network is down.
maybe_bootstrap_models() ->
    Specs = bootstrap_specs(),
    case Specs of
        [] ->
            ok;
        _ ->
            spawn(fun() -> run_bootstrap(Specs) end),
            ok
    end.

bootstrap_specs() ->
    FromEnv =
        case os:getenv("ERLLAMA_BOOTSTRAP_MODELS") of
            false -> [];
            "" -> [];
            S -> [string:trim(X) || X <- string:split(S, ",", all), X =/= ""]
        end,
    FromCfg = application:get_env(erllama_server, bootstrap_models, []),
    Combined = FromCfg ++ [list_to_binary(X) || X <- FromEnv, X =/= ""],
    [to_bin(Spec) || Spec <- Combined].

run_bootstrap(Specs) ->
    logger:notice("erllama_server: bootstrap pulling ~B model(s)", [length(Specs)]),
    lists:foreach(fun bootstrap_one/1, Specs).

bootstrap_one(Spec) ->
    try erllama_server_models:pull(Spec) of
        {ok, _} ->
            logger:notice("erllama_server: bootstrap pulled ~ts", [Spec]),
            ok;
        {error, Reason} ->
            logger:warning(
                "erllama_server: bootstrap pull failed for ~ts: ~p",
                [Spec, Reason]
            ),
            ok
    catch
        Class:Why ->
            logger:warning(
                "erllama_server: bootstrap pull crashed for ~ts: ~p:~p",
                [Spec, Class, Why]
            ),
            ok
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

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
