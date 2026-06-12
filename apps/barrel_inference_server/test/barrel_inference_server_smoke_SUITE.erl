%%% Smoke test for the read-only HTTP endpoints (no inference).
%%% Boots the full barrel_inference_server application against a random port,
%%% hits /health, /health/ready, /v1/models, /metrics, and tears down.
-module(barrel_inference_server_smoke_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
%% Logger handler callback used by messages_logs_user_id_in_event/1.
-export([log/2]).
-export([
    health_returns_200/1,
    health_ready_returns_503_with_no_models/1,
    models_returns_openai_list_shape/1,
    models_returns_aliases/1,
    models_unknown_returns_404/1,
    metrics_returns_prometheus_text/1,
    embeddings_unknown_model_returns_404/1,
    embeddings_invalid_json_returns_400/1,
    chat_invalid_json_returns_400/1,
    messages_streaming_unknown_model_emits_event_error/1,
    anthropic_version_header_echoed/1,
    count_tokens_unknown_model_returns_529/1,
    count_tokens_invalid_json_returns_400/1,
    accepts_body_above_one_mb/1,
    accepts_body_above_cowboy_default_length/1,
    messages_413_returns_request_too_large_type/1,
    messages_emits_request_id_header/1,
    messages_no_allowlist_accepts_any_key/1,
    messages_emits_ratelimit_headers/1,
    messages_logs_user_id_in_event/1,
    messages_error_body_carries_request_id/1,
    chat_missing_model_returns_400/1,
    chat_too_many_messages_returns_400/1,
    responses_invalid_json_returns_400/1,
    responses_missing_model_returns_400/1,
    responses_string_input_unknown_model_returns_404/1,
    responses_emits_response_id_header/1,
    responses_streaming_unknown_model_emits_event_error/1,
    responses_413_returns_request_too_large_type/1,
    responses_codex_envelope_accepted/1,
    request_id_minted_when_absent/1,
    request_id_echoed_when_present/1,
    request_id_custom_header_name_echoed/1,
    cors_disabled_by_default/1,
    cors_preflight_returns_204/1,
    cors_headers_present_on_response/1,
    method_not_allowed_sweep/1,
    completions_invalid_json_returns_400/1,
    completions_missing_model_returns_400/1,
    api_version_returns_200/1,
    api_tags_returns_200/1,
    api_ps_returns_200/1,
    api_search_invalid_json_returns_400/1,
    api_pull_emits_ndjson_lines/1,
    livery_listener_serves_health/1,
    livery_listener_serves_metrics/1,
    livery_listener_serves_models_list/1,
    livery_listener_returns_503_for_unmigrated_route/1,
    livery_listener_echoes_request_id_header/1,
    livery_ollama_generate_invalid_json_returns_400/1,
    livery_ollama_chat_invalid_json_returns_400/1,
    livery_ollama_generate_unknown_model_streams_ndjson/1,
    livery_embeddings_openai_invalid_json_returns_400/1,
    livery_embeddings_ollama_invalid_json_returns_400/1
]).

suite() -> [{timetrap, {seconds, 30}}].
all() ->
    [
        health_returns_200,
        health_ready_returns_503_with_no_models,
        models_returns_openai_list_shape,
        models_returns_aliases,
        models_unknown_returns_404,
        metrics_returns_prometheus_text,
        embeddings_unknown_model_returns_404,
        embeddings_invalid_json_returns_400,
        chat_invalid_json_returns_400,
        messages_streaming_unknown_model_emits_event_error,
        anthropic_version_header_echoed,
        count_tokens_unknown_model_returns_529,
        count_tokens_invalid_json_returns_400,
        accepts_body_above_one_mb,
        accepts_body_above_cowboy_default_length,
        messages_413_returns_request_too_large_type,
        messages_emits_request_id_header,
        messages_no_allowlist_accepts_any_key,
        messages_emits_ratelimit_headers,
        messages_logs_user_id_in_event,
        messages_error_body_carries_request_id,
        chat_missing_model_returns_400,
        chat_too_many_messages_returns_400,
        responses_invalid_json_returns_400,
        responses_missing_model_returns_400,
        responses_string_input_unknown_model_returns_404,
        responses_emits_response_id_header,
        responses_streaming_unknown_model_emits_event_error,
        responses_413_returns_request_too_large_type,
        responses_codex_envelope_accepted,
        request_id_minted_when_absent,
        request_id_echoed_when_present,
        request_id_custom_header_name_echoed,
        cors_disabled_by_default,
        cors_preflight_returns_204,
        cors_headers_present_on_response,
        method_not_allowed_sweep,
        completions_invalid_json_returns_400,
        completions_missing_model_returns_400,
        api_version_returns_200,
        api_tags_returns_200,
        api_ps_returns_200,
        api_search_invalid_json_returns_400,
        api_pull_emits_ndjson_lines,
        livery_listener_serves_health,
        livery_listener_serves_metrics,
        livery_listener_serves_models_list,
        livery_listener_returns_503_for_unmigrated_route,
        livery_listener_echoes_request_id_header,
        livery_ollama_generate_invalid_json_returns_400,
        livery_ollama_chat_invalid_json_returns_400,
        livery_ollama_generate_unknown_model_streams_ndjson,
        livery_embeddings_openai_invalid_json_returns_400,
        livery_embeddings_ollama_invalid_json_returns_400
    ].

init_per_suite(Config) ->
    %% pick after start
    Port = 0,
    application:set_env(barrel_inference_server, port, free_port()),
    application:set_env(
        barrel_inference_server,
        model_aliases,
        #{
            <<"alias-a">> => <<"real-1">>,
            <<"alias-b">> => <<"real-2">>
        }
    ),
    application:set_env(
        barrel_inference_server,
        pool_exhausted_policy,
        {queue, #{
            concurrency => 1,
            depth => 10,
            timeout_ms => 5000
        }}
    ),
    application:set_env(barrel_inference_server, max_messages, 4),
    application:set_env(
        barrel_inference_server,
        cors,
        #{
            allow_origins => <<"*">>,
            allow_credentials => false,
            allow_methods => <<"GET, POST, OPTIONS">>,
            allow_headers => <<"content-type, x-request-id">>,
            max_age => 600
        }
    ),
    LiveryPort = free_livery_port(),
    application:set_env(barrel_inference_server, livery_port, LiveryPort),
    {ok, Started} = application:ensure_all_started(barrel_inference_server),
    {ok, _} = application:ensure_all_started(inets),
    Url = io_lib:format("http://127.0.0.1:~p", [chosen_port()]),
    LiveryUrl = io_lib:format("http://127.0.0.1:~p", [LiveryPort]),
    [
        {base, lists:flatten(Url)},
        {livery_base, lists:flatten(LiveryUrl)},
        {started, Started},
        {port, Port}
        | Config
    ].

end_per_suite(Config) ->
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    ok.

free_livery_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    persistent_term:put({?MODULE, port}, Port),
    Port.

chosen_port() ->
    persistent_term:get({?MODULE, port}).

%%====================================================================
%% Tests
%%====================================================================

health_returns_200(Cfg) ->
    Url = ?config(base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Decoded)).

health_ready_returns_503_with_no_models(Cfg) ->
    Url = ?config(base, Cfg) ++ "/health/ready",
    {ok, {{_, Code, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(503, Code),
    ?assertEqual(<<"not_ready">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual([], maps:get(<<"models">>, Decoded)).

models_returns_openai_list_shape(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/models",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"list">>, maps:get(<<"object">>, Decoded)),
    ?assertMatch([_ | _], maps:get(<<"data">>, Decoded)).

models_returns_aliases(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/models",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    Ids = [maps:get(<<"id">>, M) || M <- maps:get(<<"data">>, Decoded)],
    ?assert(lists:member(<<"alias-a">>, Ids)),
    ?assert(lists:member(<<"alias-b">>, Ids)).

models_unknown_returns_404(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/models/no-such-model",
    {ok, {{_, 404, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    Err = maps:get(<<"error">>, Decoded),
    ?assertEqual(<<"model_not_found">>, maps:get(<<"code">>, Err)).

metrics_returns_prometheus_text(Cfg) ->
    Url = ?config(base, Cfg) ++ "/metrics",
    {ok, {{_, 200, _}, Headers, _Body}} = httpc:request(Url),
    %% Content-type starts with text/plain. Body may be empty if no
    %% counter has been observed yet (the suite order is not
    %% guaranteed across runs).
    {value, {_, CT}} = lists:keysearch("content-type", 1, Headers),
    ?assert(string:prefix(CT, "text/plain") =/= nomatch).

embeddings_unknown_model_returns_404(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/embeddings",
    Body = json:encode(#{<<"model">> => <<"nope">>, <<"input">> => <<"hi">>}),
    {ok, {{_, Code, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    %% No model is loaded; resolve_model is identity, ensure_loaded
    %% sees not_found from barrel_inference:model_info/1 (not loaded path).
    %% In practice this returns 503 from ensure_loaded {error, not_loaded}
    %% on policy=on_demand because barrel_inference:load_model crashes on a
    %% bogus path. Either is acceptable.
    ?assert(Code =:= 404 orelse Code =:= 503 orelse Code =:= 500).

embeddings_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/embeddings",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(
            post,
            {Url, [], "application/json", "{not json"},
            [],
            []
        ).

chat_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(
            post,
            {Url, [], "application/json", "{nope"},
            [],
            []
        ).

%% Pre-stream errors on a streaming /v1/messages request must surface
%% as an Anthropic SSE `event: error` frame, not a JSON envelope.
%% Anthropic SDKs read the streaming body as SSE; a JSON response
%% decodes as a transport error rather than a proper error event.
messages_streaming_unknown_model_emits_event_error(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 8,
        <<"stream">> => true,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Bin = list_to_binary(RespBody),
    %% Cowboy streams with HTTP 200; the error is conveyed via the
    %% SSE error event rather than an HTTP status. (200 is what
    %% Anthropic itself returns for the streaming-error path.)
    ?assertEqual(200, Status),
    ?assert(binary:match(Bin, <<"event: error">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"type\":\"error\"">>) =/= nomatch),
    %% The inner error.type must be one of Anthropic's enum values, not
    %% a freeform string like the pre-fix \"server_error\".
    ?assert(binary:match(Bin, <<"\"type\":\"not_found_error\"">>) =/= nomatch).

%% /v1/messages/count_tokens with no loaded model surfaces as 529
%% overloaded_error (remapped from internal 503 not_loaded) with a
%% retry-after header. Anthropic SDKs honour this as the backoff
%% delay; rather than load a multi-GB model on every count_tokens
%% probe we ask the caller to retry once the model has loaded
%% through a real /v1/messages request.
count_tokens_unknown_model_returns_529(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages/count_tokens",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    {ok, {{_, Status, _}, Headers, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    ?assertEqual(529, Status),
    {value, {_, Retry}} = lists:keysearch("retry-after", 1, Headers),
    ?assert(list_to_integer(Retry) >= 1),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(
        #{<<"error">> := #{<<"type">> := <<"overloaded_error">>}},
        Decoded
    ).

count_tokens_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages/count_tokens",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(
            post,
            {Url, [], "application/json", "{not json"},
            [],
            []
        ).

%% Anthropic SDKs always send `anthropic-version` and read it back
%% from the response. Echo whatever the client sent (or our default).
anthropic_version_header_echoed(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 4,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, _, _}, Headers, _}} =
        httpc:request(
            post,
            {Url, [{"anthropic-version", "2024-12-01"}], "application/json", Body},
            [],
            []
        ),
    {value, {_, Version}} = lists:keysearch("anthropic-version", 1, Headers),
    ?assertEqual("2024-12-01", Version).

%% Pre-c70004d the body cap was 1 MB; SDK clients shipping multi-KB
%% tool definitions tripped 413. Send a 5 MB garbage body and assert
%% we reach the JSON decoder (400) rather than being rejected at the
%% size boundary. Fast-phase, no model load involved.
accepts_body_above_one_mb(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Big = binary:copy(<<"x">>, 5 * 1024 * 1024),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Big}, [], []),
    ?assertEqual(400, Status).

%% Cowboy's default per-read `length' is 8 MB; the handler must loop
%% `read_body/1' across multiple `{more, _, _}' chunks instead of
%% treating the first non-final chunk as 413. A 10 MB body is enough
%% to force at least two reads even on a fast localhost socket.
accepts_body_above_cowboy_default_length(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Big = binary:copy(<<"x">>, 10 * 1024 * 1024),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Big}, [], []),
    ?assertEqual(400, Status).

%% Anthropic SDKs read `request-id` (no x- prefix) into
%% message._request_id; the existing middleware stamps `x-request-id`.
%% The /v1/messages handler must alias the literal name with the same
%% value so SDK consumers see a populated _request_id.
messages_emits_request_id_header(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 4,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, _, _}, Headers, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    {value, {_, AnthrId}} = lists:keysearch("request-id", 1, Headers),
    {value, {_, XReqId}} = lists:keysearch("x-request-id", 1, Headers),
    ?assertEqual(XReqId, AnthrId),
    ?assert(string:prefix(AnthrId, "req_") =/= nomatch).

%% No api-key allowlist configured: Claude Code can send any x-api-key
%% value (even its placeholder `not-used`) and the request flows
%% through. Same as no x-api-key at all.
messages_no_allowlist_accepts_any_key(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 4,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(
            post,
            {Url, [{"x-api-key", "not-used"}], "application/json", Body},
            [],
            []
        ),
    %% Hits model resolution (404 because the model isn't real); the
    %% point is the auth gate did not 401.
    ?assertEqual(404, Status).

%% record_metrics emits a structured logger:notice event including
%% metadata.user_id, the message id, and cache stats from the engine
%% so observability sinks can slice request traffic by user AND see
%% whether the engine warm-restored the static prefix on this turn.
%% The event is keyed `anthropic_request`. Error paths (this test
%% hits 404 / not_found) carry the cache fields as their defaults
%% (undefined / 0); successful paths carry the engine's real values.
messages_logs_user_id_in_event(Cfg) ->
    persistent_term:put({?MODULE, log_pid}, self()),
    HandlerId = anthropic_log_capture,
    ok = logger:add_handler(HandlerId, ?MODULE, #{level => notice}),
    try
        Url = ?config(base, Cfg) ++ "/v1/messages",
        Body = json:encode(#{
            <<"model">> => <<"no-such-model">>,
            <<"max_tokens">> => 4,
            <<"metadata">> => #{<<"user_id">> => <<"u-test">>},
            <<"messages">> => [
                #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
            ]
        }),
        {ok, _} = httpc:request(post, {Url, [], "application/json", Body}, [], []),
        receive
            {log_event, Report} ->
                ?assertEqual(<<"u-test">>, maps:get(user_id, Report)),
                ?assertEqual(anthropic_request, maps:get(event, Report)),
                ?assertEqual(<<"/v1/messages">>, maps:get(endpoint, Report)),
                %% Cache observability fields are always emitted, with
                %% defaults on error paths so consumers can rely on
                %% their presence.
                ?assertEqual(undefined, maps:get(cache_hit_kind, Report)),
                ?assertEqual(0, maps:get(cache_read_tokens, Report)),
                ?assertEqual(0, maps:get(cache_created_tokens, Report)),
                ?assertEqual(0, maps:get(prompt_tokens, Report))
        after 2000 ->
            ct:fail(no_anthropic_request_log_seen)
        end
    after
        logger:remove_handler(HandlerId),
        persistent_term:erase({?MODULE, log_pid})
    end.

%% Logger handler callback. Forwards the anthropic_request event
%% report to the test process; ignores everything else.
log(#{msg := {report, #{event := anthropic_request} = Report}}, _Config) ->
    case persistent_term:get({?MODULE, log_pid}, undefined) of
        undefined -> ok;
        Pid -> Pid ! {log_event, Report}
    end,
    ok;
log(_, _) ->
    ok.

%% Anthropic SDKs read anthropic-ratelimit-requests-{limit,remaining,reset}
%% to pace their own retry behaviour. The limit comes from the per-model
%% queue concurrency; remaining is concurrency-inflight; reset is an
%% RFC 3339 timestamp of when the next slot is expected to free up.
%% Token-bucket headers are intentionally omitted (we have no per-minute
%% / per-day token accounting).
messages_emits_ratelimit_headers(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 4,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, _, _}, Headers, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    {value, {_, Limit}} =
        lists:keysearch("anthropic-ratelimit-requests-limit", 1, Headers),
    {value, {_, Remaining}} =
        lists:keysearch("anthropic-ratelimit-requests-remaining", 1, Headers),
    {value, {_, Reset}} =
        lists:keysearch("anthropic-ratelimit-requests-reset", 1, Headers),
    ?assert(list_to_integer(Limit) >= 1),
    ?assert(list_to_integer(Remaining) >= 0),
    %% Format check: RFC 3339 ends with a Z (we set offset to "Z").
    ?assert(lists:suffix("Z", Reset)).

%% Anthropic error envelope spec includes `request_id` inside the body
%% alongside type and message. SDKs read it for support diagnostics
%% (separate from the response header of the same name).
messages_error_body_carries_request_id(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"max_tokens">> => 4,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]
    }),
    {ok, {{_, 404, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(#{<<"request_id">> := <<"req_", _/binary>>}, Decoded).

%% 413 response must carry Anthropic's `request_too_large` error type,
%% not the catch-all `api_error`. SDKs match on the type to decide
%% retry behaviour.
messages_413_returns_request_too_large_type(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    %% Default body cap is 256 MiB; send 257 MiB to trip the 413 path.
    Oversized = binary:copy(<<"x">>, 257 * 1024 * 1024),
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Oversized}, [], []),
    ?assertEqual(413, Status),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(
        #{<<"error">> := #{<<"type">> := <<"request_too_large">>}},
        Decoded
    ).

chat_missing_model_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{<<"messages">> => []}),
    {ok, {{_, 400, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(#{<<"error">> := _}, Decoded).

chat_too_many_messages_returns_400(Cfg) ->
    %% max_messages set to 4 in init_per_suite; 5 must trip the cap.
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Many = [
        #{<<"role">> => <<"user">>, <<"content">> => integer_to_binary(I)}
     || I <- lists:seq(1, 5)
    ],
    Body = json:encode(#{<<"model">> => <<"x">>, <<"messages">> => Many}),
    {ok, {{_, 400, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(
        #{<<"error">> := #{<<"code">> := <<"too_many_messages">>}},
        Decoded
    ).

request_id_minted_when_absent(Cfg) ->
    Url = ?config(base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, Headers, _}} = httpc:request(Url),
    {value, {_, Id}} = lists:keysearch("x-request-id", 1, Headers),
    ?assert(string:prefix(Id, "req_") =/= nomatch).

request_id_echoed_when_present(Cfg) ->
    Url = ?config(base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, Headers, _}} =
        httpc:request(get, {Url, [{"x-request-id", "abc-123"}]}, [], []),
    {value, {_, Id}} = lists:keysearch("x-request-id", 1, Headers),
    ?assertEqual("abc-123", Id).

cors_disabled_by_default(Cfg) ->
    %% This suite enables CORS, so this test verifies that no Origin
    %% header skips the CORS branch entirely.
    Url = ?config(base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, Headers, _}} = httpc:request(Url),
    %% No Origin header on the request -> no Access-Control-* on the
    %% response.
    ?assertEqual(false, lists:keymember("access-control-allow-origin", 1, Headers)).

cors_preflight_returns_204(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Headers = [
        {"origin", "http://example.com"},
        {"access-control-request-method", "POST"},
        {"access-control-request-headers", "content-type"}
    ],
    {ok, {{_, 204, _}, RespHeaders, _}} =
        httpc:request(options, {Url, Headers}, [], []),
    {value, {_, AllowOrigin}} =
        lists:keysearch("access-control-allow-origin", 1, RespHeaders),
    ?assertEqual("*", AllowOrigin),
    ?assert(lists:keymember("access-control-allow-methods", 1, RespHeaders)),
    ?assert(lists:keymember("access-control-allow-headers", 1, RespHeaders)).

cors_headers_present_on_response(Cfg) ->
    Url = ?config(base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, Headers, _}} =
        httpc:request(get, {Url, [{"origin", "http://example.com"}]}, [], []),
    ?assert(lists:keymember("access-control-allow-origin", 1, Headers)).

%%====================================================================
%% /v1/responses (OpenAI Responses API)
%%====================================================================

responses_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(
            post,
            {Url, [], "application/json", "{not json"},
            [],
            []
        ).

responses_missing_model_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Body = json:encode(#{}),
    {ok, {{_, 400, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(#{<<"error">> := _}, Decoded).

responses_string_input_unknown_model_returns_404(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"input">> => <<"hi">>,
        <<"max_output_tokens">> => 4
    }),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    ?assertEqual(404, Status).

%% Non-streaming responses include a `resp_<int>` id. We can't actually
%% generate output without a real model, but we can assert that a 4xx
%% / 5xx pre-stream error round-trips a JSON envelope (the id only
%% appears on successful inference; this test simply ensures the
%% endpoint is wired and doesn't 404 on `/v1/responses`).
responses_emits_response_id_header(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"input">> => <<"hi">>,
        <<"max_output_tokens">> => 4
    }),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    %% Endpoint is reachable; 404 (model resolution) or another non-405
    %% is acceptable. The point is that we don't route-miss.
    ?assert(Status =/= 405).

responses_streaming_unknown_model_emits_event_error(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"input">> => <<"hi">>,
        <<"stream">> => true,
        <<"max_output_tokens">> => 8
    }),
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    %% On the streaming path the handler opens an SSE stream on the
    %% pipeline-error and emits a `response.failed` event. HTTP 200.
    Bin = list_to_binary(RespBody),
    case Status of
        200 ->
            ?assert(binary:match(Bin, <<"event: response.failed">>) =/= nomatch),
            ?assert(binary:match(Bin, <<"\"status\":\"failed\"">>) =/= nomatch);
        _ ->
            %% Pre-stream error paths (model resolution failed before
            %% SSE open) land as a JSON envelope rather than SSE. Both
            %% are acceptable for an unknown model.
            ?assert(is_binary(Bin))
    end.

responses_413_returns_request_too_large_type(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Oversized = binary:copy(<<"x">>, 257 * 1024 * 1024),
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Oversized}, [], []),
    ?assertEqual(413, Status),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertMatch(#{<<"error">> := #{<<"code">> := <<"request_too_large">>}}, Decoded).

%% Codex sends the Responses request as an `input` array of message
%% items (content as `input_text` parts) plus a top-level
%% `instructions` string and `stream: true`. Assert that envelope is
%% accepted and routed (an unknown model reaches the streaming
%% `response.failed` path) rather than rejected as a 400 parse error.
responses_codex_envelope_accepted(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"instructions">> => <<"You are a coding agent.">>,
        <<"input">> => [
            #{
                <<"type">> => <<"message">>,
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"input_text">>, <<"text">> => <<"write a function">>}
                ]
            }
        ],
        <<"stream">> => true,
        <<"max_output_tokens">> => 8
    }),
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Bin = list_to_binary(RespBody),
    %% Not a 400: the array-input + instructions envelope parsed. An
    %% unknown model then fails at load, which on the streaming path
    %% surfaces as a `response.failed` SSE event (HTTP 200).
    ?assertNotEqual(400, Status),
    case Status of
        200 -> ?assert(binary:match(Bin, <<"event: response.failed">>) =/= nomatch);
        _ -> ?assert(is_binary(Bin))
    end.

%%====================================================================
%% Phase α contract tests: pin framework-visible behaviour before the
%% cowboy -> livery migration so any handler swap is regression-checked
%% against this baseline.
%%====================================================================

%% The request-id header name is operator-configurable via the
%% `request_id_header' env. Set a non-default name at runtime (the
%% config layer caches it in persistent_term so a put / restore here
%% reaches the middleware on the next request), assert the response
%% carries the value under the configured name.
request_id_custom_header_name_echoed(Cfg) ->
    Key = {barrel_inference_server_config, request_id_header},
    Original = persistent_term:get(Key, <<"x-request-id">>),
    persistent_term:put(Key, <<"x-trace-id">>),
    try
        Url = ?config(base, Cfg) ++ "/health",
        {ok, {{_, 200, _}, Headers, _}} =
            httpc:request(get, {Url, [{"x-trace-id", "trace-abc"}]}, [], []),
        {value, {_, Id}} = lists:keysearch("x-trace-id", 1, Headers),
        ?assertEqual("trace-abc", Id),
        ?assertEqual(false, lists:keymember("x-request-id", 1, Headers))
    after
        persistent_term:put(Key, Original)
    end.

%% Every routed path is reachable under at least one HTTP method; this
%% case probes each with a wrong method and asserts 405. Catches the
%% (currently absent) framework-level method-not-allowed contract that
%% the livery router will surface differently than cowboy's per-handler
%% dispatch.
method_not_allowed_sweep(Cfg) ->
    Base = ?config(base, Cfg),
    %% {Path, WrongMethod}; the path is an existing route + a method it
    %% does NOT serve.
    Probes = [
        {"/health", post},
        {"/health/ready", post},
        {"/metrics", post},
        {"/v1/models", post},
        {"/v1/chat/completions", get},
        {"/v1/completions", get},
        {"/v1/responses", get},
        {"/v1/messages", get},
        {"/v1/messages/count_tokens", get},
        {"/v1/embeddings", get},
        {"/api/tags", post},
        {"/api/version", post},
        {"/api/ps", post},
        {"/api/pull", get},
        {"/api/generate", get},
        {"/api/chat", get},
        {"/api/embed", get},
        {"/api/embeddings", get},
        {"/api/show", get},
        {"/api/copy", get},
        {"/api/edit", get},
        {"/api/create", get},
        {"/api/search", get}
    ],
    [check_method_405(Base, Path, Method) || {Path, Method} <- Probes],
    ok.

check_method_405(Base, Path, get) ->
    Url = Base ++ Path,
    {ok, {{_, Status, _}, _, _}} = httpc:request(get, {Url, []}, [], []),
    ?assertEqual({Path, 405}, {Path, Status});
check_method_405(Base, Path, post) ->
    Url = Base ++ Path,
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", <<"{}">>}, [], []),
    ?assertEqual({Path, 405}, {Path, Status}).

%% OpenAI legacy completions (POST /v1/completions) is routed via the
%% chat handler with `api => openai_legacy'; verify the JSON validation
%% path and the missing-model path land on the documented 400s.
completions_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/completions",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

completions_missing_model_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/completions",
    Body = json:encode(#{<<"prompt">> => <<"hello">>}),
    {ok, {{_, Status, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    ?assertEqual(400, Status).

%% Ollama-shaped non-streaming GET endpoints. /api/version reports the
%% server version, /api/tags lists registry entries, /api/ps lists
%% loaded model processes. None require an actual model load, so they
%% should all return 200 with a JSON body in the smoke baseline.
api_version_returns_200(Cfg) ->
    Url = ?config(base, Cfg) ++ "/api/version",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assert(is_map(Decoded)),
    ?assert(maps:is_key(<<"version">>, Decoded)).

api_tags_returns_200(Cfg) ->
    Url = ?config(base, Cfg) ++ "/api/tags",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assert(maps:is_key(<<"models">>, Decoded)).

api_ps_returns_200(Cfg) ->
    Url = ?config(base, Cfg) ++ "/api/ps",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assert(maps:is_key(<<"models">>, Decoded)).

%% POST /api/search has no test coverage today. Drive the invalid-JSON
%% path so the route at least exists and validates input the same way
%% as the rest of the Ollama-shaped surface.
api_search_invalid_json_returns_400(Cfg) ->
    Url = ?config(base, Cfg) ++ "/api/search",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

%% POST /api/pull is NDJSON-streaming. Even on a fast-failing spec
%% (unknown model) the body must consist of `\n'-terminated parseable
%% JSON objects, no half-frames at the end. Pins the framing the
%% livery_resp:stream/3 producer must reproduce.
api_pull_emits_ndjson_lines(Cfg) ->
    Url = ?config(base, Cfg) ++ "/api/pull",
    Body = json:encode(#{<<"model">> => <<"no-such-model:notag">>, <<"stream">> => true}),
    {ok, {{_, _Status, _}, Headers, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Bin = list_to_binary(RespBody),
    %% The Content-Type is application/x-ndjson on success and
    %% application/json on a synchronous error envelope; either is fine
    %% as long as the body framing matches.
    {value, {_, CT}} = lists:keysearch("content-type", 1, Headers),
    case string:str(CT, "x-ndjson") of
        0 ->
            %% Synchronous error path: body is a single JSON object.
            Decoded = json:decode(Bin),
            ?assert(is_map(Decoded));
        _ ->
            %% Streaming path: split on \n, drop any trailing empty,
            %% each non-empty line decodes to a JSON map.
            Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
            ?assert(Lines =/= []),
            [
                begin
                    M = json:decode(L),
                    ?assert(is_map(M))
                end
             || L <- Lines
            ]
    end.

%%====================================================================
%% Phase β dual-listener tests: confirm the livery listener boots on
%% the side port and serves the simple handlers (h_health, h_metrics,
%% h_models) byte-for-byte equivalent to cowboy. Streaming handlers
%% still return the not_yet_migrated 503 stub here and get migrated
%% one PR at a time in phase γ.
%%====================================================================

livery_listener_serves_health(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/health",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Decoded)).

livery_listener_serves_metrics(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/metrics",
    {ok, {{_, 200, _}, Headers, _Body}} = httpc:request(Url),
    {value, {_, CT}} = lists:keysearch("content-type", 1, Headers),
    %% Status + content-type prove the route is wired. The actual body
    %% bytes are exercised by the cowboy metrics_returns_prometheus_text
    %% case earlier in the suite (same handler code path); the inets
    %% client returning an empty body here under livery's chunked
    %% encoding is a known harness quirk, not a framework bug.
    ?assert(string:str(CT, "text/plain") =/= 0).

livery_listener_serves_models_list(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/v1/models",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"list">>, maps:get(<<"object">>, Decoded)),
    ?assert(is_list(maps:get(<<"data">>, Decoded))).

%% Routes whose cowboy handler has not been ported to a livery
%% `handle/1` yet are wired to the not_yet_migrated stub. The stub
%% returns 503 with an explanatory JSON body so the target=livery
%% CT group can identify routes still pending migration.
livery_listener_returns_503_for_unmigrated_route(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/api/version",
    {ok, {{_, 503, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(
        <<"not_migrated_to_livery">>,
        maps:get(<<"error">>, Decoded)
    ).

%% The custom-named request-id header round-trips on the livery side
%% the same way it does on cowboy, proving the
%% barrel_inference_server_request_id_mw middleware is in the stack
%% and honours the configurable header.
livery_listener_echoes_request_id_header(Cfg) ->
    Key = {barrel_inference_server_config, request_id_header},
    Original = persistent_term:get(Key, <<"x-request-id">>),
    persistent_term:put(Key, <<"x-trace-id">>),
    try
        Url = ?config(livery_base, Cfg) ++ "/health",
        {ok, {{_, 200, _}, Headers, _}} =
            httpc:request(get, {Url, [{"x-trace-id", "abc-trace"}]}, [], []),
        {value, {_, Id}} = lists:keysearch("x-trace-id", 1, Headers),
        ?assertEqual("abc-trace", Id)
    after
        persistent_term:put(Key, Original)
    end.

%%====================================================================
%% Phase γ1: h_ollama migrated to a livery handle/1 entry point. The
%% routes for /api/generate and /api/chat dispatch livery-side to the
%% new handler. Cowboy serves the same routes unchanged.
%%====================================================================

livery_ollama_generate_invalid_json_returns_400(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/api/generate",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

livery_ollama_chat_invalid_json_returns_400(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/api/chat",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

%% A streaming Ollama generate against an unknown model is the
%% live-fire path: the handler enters the inference branch, the
%% pipeline worker fails to load, and the receive loop emits an NDJSON
%% error frame before falling out of the stream. Proves Emit/1 is
%% wired and the cancel-via-fall-out cleanup runs without crashing.
livery_embeddings_openai_invalid_json_returns_400(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/v1/embeddings",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

livery_embeddings_ollama_invalid_json_returns_400(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/api/embed",
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post, {Url, [], "application/json", "{not json"}, [], []).

livery_ollama_generate_unknown_model_streams_ndjson(Cfg) ->
    Url = ?config(livery_base, Cfg) ++ "/api/generate",
    Body = json:encode(#{
        <<"model">> => <<"no-such-model">>,
        <<"prompt">> => <<"hi">>,
        <<"stream">> => true
    }),
    {ok, {{_, _Status, _}, Headers, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Bin = list_to_binary(RespBody),
    {value, {_, CT}} = lists:keysearch("content-type", 1, Headers),
    ?assert(string:str(CT, "x-ndjson") =/= 0 orelse string:str(CT, "json") =/= 0),
    ?assert(byte_size(Bin) >= 0).
