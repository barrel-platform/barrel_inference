-module(barrel_inference_server_app).
-behaviour(application).

-export([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
    ok = barrel_inference_server_metrics:init(),
    ok = ensure_model_default_opts(),
    ok = ensure_thinking_signing_key(),
    case barrel_inference_server_sup:start_link() of
        {ok, _Sup} = OK ->
            ok = maybe_bootstrap_models(),
            ok = maybe_start_livery_listener(),
            OK;
        E ->
            E
    end.

%% Optional livery listener for the migration window. When the
%% `livery_port' env is unset the listener is not started and only the
%% cowboy listener serves traffic. When set, both listeners run
%% side-by-side on different ports so a CT suite (or an operator who
%% wants to probe the new stack) can target livery directly without
%% replacing the production listener. The cowboy listener stays the
%% default until phase δ flips the production port.
maybe_start_livery_listener() ->
    case application:get_env(barrel_inference_server, livery_port, undefined) of
        undefined ->
            ok;
        Port when is_integer(Port) ->
            Routes = barrel_inference_server_routes:livery_routes(),
            Router = livery_router:compile(Routes),
            Stack = livery_middleware_stack(),
            HttpOpts = #{
                port => Port,
                ip => application:get_env(barrel_inference_server, livery_ip, {0, 0, 0, 0}),
                acceptors =>
                    application:get_env(barrel_inference_server, livery_acceptors, 100),
                idle_timeout =>
                    application:get_env(
                        barrel_inference_server,
                        livery_idle_timeout_ms,
                        1800000
                    )
            },
            Config = #{http => HttpOpts, router => Router, middleware => Stack},
            {ok, ServicePid} = livery:start_service(Config),
            persistent_term:put({?MODULE, livery_service_pid}, ServicePid),
            ok
    end.

livery_middleware_stack() ->
    [
        {barrel_inference_server_request_id_mw, undefined},
        {barrel_inference_server_cors_mw, undefined},
        {barrel_inference_server_access_log_mw, undefined}
    ].

%% barrel_inference 0.4.0 reads `application:get_env(barrel_inference, thinking_signing_key)`
%% to HMAC-sign extended-thinking blocks. We accept the key on our
%% own env (so operators configure one place) and forward it to the
%% engine before any model load. Unset / empty disables signing;
%% the engine then emits <<>> signatures and the SSE layer omits
%% signature_delta entirely.
ensure_thinking_signing_key() ->
    case application:get_env(barrel_inference_server, thinking_signing_key, undefined) of
        undefined ->
            ok;
        <<>> ->
            ok;
        Key when is_binary(Key) ->
            application:set_env(barrel_inference, thinking_signing_key, Key),
            ok;
        _ ->
            logger:warning(
                "barrel_inference_server: thinking_signing_key must be a non-empty"
                " binary; signing disabled"
            ),
            ok
    end.

%% On boot, kick off a background pull for any spec listed in the
%% `bootstrap_models` app env (or the `BARREL_INFERENCE_BOOTSTRAP_MODELS` env
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
        case os:getenv("BARREL_INFERENCE_BOOTSTRAP_MODELS") of
            false -> [];
            "" -> [];
            S -> [string:trim(X) || X <- string:split(S, ",", all), X =/= ""]
        end,
    FromCfg = application:get_env(barrel_inference_server, bootstrap_models, []),
    Combined = FromCfg ++ [list_to_binary(X) || X <- FromEnv, X =/= ""],
    [to_bin(Spec) || Spec <- Combined].

run_bootstrap(Specs) ->
    logger:notice("barrel_inference_server: bootstrap pulling ~B model(s)", [length(Specs)]),
    lists:foreach(fun bootstrap_one/1, Specs).

bootstrap_one(Spec) ->
    try barrel_inference_server_models:pull(Spec) of
        {ok, _} ->
            logger:notice("barrel_inference_server: bootstrap pulled ~ts", [Spec]),
            ok;
        {error, Reason} ->
            logger:warning(
                "barrel_inference_server: bootstrap pull failed for ~ts: ~p",
                [Spec, Reason]
            ),
            ok
    catch
        Class:Why ->
            logger:warning(
                "barrel_inference_server: bootstrap pull crashed for ~ts: ~p:~p",
                [Spec, Class, Why]
            ),
            ok
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

%% Bake the default `barrel_inference:load_model/2` options the loader will
%% layer manifest-derived fields on top of. Operators can override
%% the whole map via `application:set_env(barrel_inference_server,
%% model_default_opts, ...)` in `sys.config`.
ensure_model_default_opts() ->
    Existing = application:get_env(barrel_inference_server, model_default_opts, undefined),
    Defaults = #{
        backend => barrel_inference_model_llama,
        tier_srv => barrel_inference_server_disk_cache,
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
    application:set_env(barrel_inference_server, model_default_opts, Merged),
    ok.

default_cache_policy() ->
    #{
        min_tokens => 64,
        cold_min_tokens => 128,
        %% Upper bound on the prompt length that gets cold prefix
        %% checkpoints at admission. Agent clients (Claude Code et al.)
        %% ship large system + tool + history prompts; below this cap
        %% cold_save returns no_save and the longest-prefix lookup never
        %% warms across turns. Cover a full 64k context (n_ctx is raised to
        %% match); the pack cost matches the finish-save we already take.
        cold_max_tokens => 65536,
        continued_interval => 2048,
        boundary_trim_tokens => 0,
        boundary_align_tokens => 16,
        %% Cold-save checkpoint ladder: write up to max_ladder_rows cold
        %% prefix checkpoints during a cold prefill, spaced ~ladder_interval
        %% tokens apart (aligned to boundary_align_tokens), so a later turn
        %% that diverges mid-prompt can still resume from a shared-head
        %% checkpoint. 0 disables (finish-save still covers the full prompt).
        ladder_interval => 16384,
        max_ladder_rows => 4,
        session_resume_wait_ms => 500
    }.

%% Application is asked to stop. Refuse new connections, then wait
%% (bounded) for in-flight streams to drain, then stop the listener.
%% Past the drain budget, cowboy:stop_listener closes stragglers.
prep_stop(State) ->
    Ref = barrel_inference_server_http,
    _ = (catch ranch:suspend_listener(Ref)),
    DeadlineMs =
        erlang:monotonic_time(millisecond) +
            application:get_env(barrel_inference_server, shutdown_timeout_ms, 5000),
    drain(Ref, DeadlineMs),
    _ = (catch cowboy:stop_listener(Ref)),
    _ = stop_livery_listener(DeadlineMs),
    State.

stop_livery_listener(DeadlineMs) ->
    case persistent_term:get({?MODULE, livery_service_pid}, undefined) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            Remaining = max(0, DeadlineMs - erlang:monotonic_time(millisecond)),
            _ = livery:drain(Pid, #{timeout => Remaining}),
            persistent_term:erase({?MODULE, livery_service_pid}),
            ok
    end.

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
