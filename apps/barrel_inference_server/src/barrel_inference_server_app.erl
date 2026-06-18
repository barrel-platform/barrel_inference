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
            ok = start_listener(),
            OK;
        E ->
            E
    end.

start_listener() ->
    Port = application:get_env(barrel_inference_server, port, 8080),
    Routes = barrel_inference_server_routes:routes(),
    Router = livery_router:compile(Routes),
    Stack = middleware_stack(),
    HttpOpts = #{
        port => Port,
        ip => application:get_env(barrel_inference_server, ip, {0, 0, 0, 0}),
        acceptors =>
            application:get_env(barrel_inference_server, num_acceptors, 100),
        %% Push our configured body cap down to livery's listener so
        %% over-cap uploads trip livery's `abort_body' (which keeps the
        %% stream alive for h1's early-response drain) instead of being
        %% caught later in the handler by `livery_body:read_all/3' Max.
        max_body => barrel_inference_server_config:max_request_body_bytes()
    },
    Config = #{http => HttpOpts, router => Router, middleware => Stack},
    {ok, ServicePid} = livery:start_service(Config),
    persistent_term:put({?MODULE, livery_service_pid}, ServicePid),
    ok.

middleware_stack() ->
    [
        {barrel_inference_server_request_id_mw, undefined},
        {barrel_inference_server_cors_mw, undefined},
        {barrel_inference_server_access_log_mw, undefined}
    ].

%% barrel_inference 0.4.0 reads `application:get_env(barrel_inference, thinking_signing_key)`
%% to HMAC-sign extended-thinking blocks. We accept the key on our
%% own env (so operators configure one place) and forward it to the
%% engine before any model load. Unset / empty disables signing.
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
        cold_max_tokens => 65536,
        continued_interval => 2048,
        boundary_trim_tokens => 0,
        boundary_align_tokens => 16,
        ladder_interval => 16384,
        max_ladder_rows => 4,
        session_resume_wait_ms => 500
    }.

%% Drain the livery listener on shutdown so in-flight streams can finish.
prep_stop(State) ->
    DeadlineMs =
        erlang:monotonic_time(millisecond) +
            application:get_env(barrel_inference_server, shutdown_timeout_ms, 5000),
    stop_listener(DeadlineMs),
    State.

stop_listener(DeadlineMs) ->
    case persistent_term:get({?MODULE, livery_service_pid}, undefined) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            Remaining = max(0, DeadlineMs - erlang:monotonic_time(millisecond)),
            _ = livery:drain(Pid, #{timeout => Remaining}),
            persistent_term:erase({?MODULE, livery_service_pid}),
            ok
    end.

stop(_State) ->
    ok.
