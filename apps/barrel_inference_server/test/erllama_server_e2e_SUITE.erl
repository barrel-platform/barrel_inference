%%% End-to-end CT suite that drives the chat / messages / embeddings
%%% endpoints against a stub-backed erllama model. Covers admission,
%%% queue exhaustion, cancel-on-disconnect, and streaming reasoning
%%% paths that the smoke suite leaves out.
%%%
%%% No real GGUF needed: the stub backend deterministically emits
%%% phash2-derived tokens, so we can drive a streaming response and
%%% assert on shape without inference quality.
-module(erllama_server_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    end_per_testcase/2
]).
-export([
    chat_streaming_emits_done_sentinel/1,
    chat_non_streaming_returns_full_response/1,
    chat_busy_returns_429/1,
    chat_cancel_on_disconnect_releases_slot/1,
    messages_streaming_emits_named_events/1,
    embeddings_returns_vector/1
]).

suite() -> [{timetrap, {seconds, 30}}].
all() ->
    [
        chat_streaming_emits_done_sentinel,
        chat_non_streaming_returns_full_response,
        %% chat_cancel + messages_streaming + embeddings all need a
        %% clean queue slot. chat_busy_returns_429 deliberately
        %% saturates the queue by spawning a Holder process and then
        %% `exit(Holder, kill)`-ing it; killing the Erlang process
        %% does NOT close the httpc-internal TCP socket, so the
        %% server-side handler keeps holding the slot until cowboy's
        %% idle_timeout fires. Running it last localises the damage.
        chat_cancel_on_disconnect_releases_slot,
        messages_streaming_emits_named_events,
        embeddings_returns_vector,
        chat_busy_returns_429
    ].

%%====================================================================
%% Setup
%%====================================================================

init_per_suite(Config) ->
    Port = free_port(),
    application:set_env(erllama_server, port, Port),
    application:set_env(erllama_server, model_aliases, #{}),
    application:set_env(
        erllama_server,
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 1, timeout_ms => 500}}
    ),
    application:set_env(erllama_server, model_load_policy, preloaded),
    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    httpc:set_options([
        {max_sessions, 16},
        {max_keep_alive_length, 0},
        {pipeline_timeout, 0}
    ]),
    Dir = make_tmp_dir(),
    DiskSrv = list_to_atom(
        "e2e_disk_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, DiskSrvPid} = erllama_cache_disk_srv:start_link(DiskSrv, Dir),
    %% start_link links the disk_srv to this init_per_suite process,
    %% which CT tears down between phases. Unlink so the disk_srv
    %% outlives this call.
    true = unlink(DiskSrvPid),
    ModelId = <<"e2e-stub">>,
    {ok, _} = erllama:load_model(ModelId, model_config(DiskSrv)),
    [
        {port, Port},
        {base, "http://127.0.0.1:" ++ integer_to_list(Port)},
        {model, ModelId},
        {disk_srv, DiskSrv},
        {dir, Dir},
        {started, Started}
        | Config
    ].

end_per_suite(Config) ->
    catch erllama:unload(?config(model, Config)),
    catch gen_server:stop(?config(disk_srv, Config)),
    rm_rf(?config(dir, Config)),
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    ok.

%% Between tests, wait for the model to return to idle so a previous
%% test's in-flight inference does not consume the queue slot of the
%% next test.
end_per_testcase(_TC, Config) ->
    Model = ?config(model, Config),
    wait_for_idle(Model, 30),
    ok.

wait_for_idle(_, 0) ->
    timeout;
wait_for_idle(Model, N) ->
    case catch erllama_model:status(Model) of
        idle ->
            ok;
        _ ->
            timer:sleep(100),
            wait_for_idle(Model, N - 1)
    end.

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_e2e_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    Dir.

rm_rf(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            [file:delete(filename:join(Dir, E)) || E <- Entries];
        _ ->
            ok
    end,
    file:del_dir(Dir),
    ok.

model_config(DiskSrv) ->
    #{
        backend => erllama_model_stub,
        tier_srv => DiskSrv,
        tier => disk,
        fingerprint => binary:copy(<<16#77>>, 32),
        fingerprint_mode => safe,
        quant_type => f16,
        quant_bits => 16,
        ctx_params_hash => binary:copy(<<16#88>>, 32),
        context_size => 1024,
        policy => #{
            min_tokens => 4,
            cold_min_tokens => 4,
            cold_max_tokens => 1000,
            continued_interval => 2048,
            boundary_trim_tokens => 0,
            boundary_align_tokens => 1,
            session_resume_wait_ms => 50
        }
    }.

%%====================================================================
%% Tests
%%====================================================================

chat_streaming_emits_done_sentinel(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"e2e-stub">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 4,
        <<"stream">> => true
    }),
    Resp = http_collect(Url, Body),
    %% Expect SSE chunks then a [DONE] sentinel.
    ?assert(binary:match(Resp, <<"data: [DONE]">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"chat.completion.chunk">>) =/= nomatch).

chat_non_streaming_returns_full_response(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"e2e-stub">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 4,
        <<"stream">> => false
    }),
    {ok, {{_, Code, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    ct:log("chat non-streaming code=~p body=~ts", [Code, RespBody]),
    ?assertEqual(200, Code),
    Decoded = json:decode(list_to_binary(RespBody)),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assert(byte_size(maps:get(<<"content">>, Msg)) > 0),
    Usage = maps:get(<<"usage">>, Decoded),
    ?assert(maps:get(<<"completion_tokens">>, Usage) >= 1).

chat_busy_returns_429(Cfg) ->
    %% concurrency=1 + depth=1 means: holder takes the slot, one
    %% waiter can queue, anything else gets pool_exhausted (429). We
    %% pick a large max_tokens so the stub backend stays busy long
    %% enough for the two follow-up requests to race.
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = iolist_to_binary(
        json:encode(#{
            <<"model">> => <<"e2e-stub">>,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"max_tokens">> => 50000,
            <<"stream">> => true
        })
    ),
    Parent = self(),
    Holder = spawn(fun() ->
        Resp = http_collect(Url, Body),
        Parent ! {holder_done, byte_size(Resp)}
    end),
    %% Wait for the holder to acquire the slot. With stream=true the
    %% server has to send the first chunk before httpc returns, so
    %% the slot is held by the time we measure.
    timer:sleep(150),
    %% Two more concurrent requests. One queues, one gets 429.
    Parent2 = self(),
    spawn(fun() ->
        Parent2 !
            {r1,
                httpc:request(
                    post,
                    {Url, [], "application/json", Body},
                    [],
                    []
                )}
    end),
    spawn(fun() ->
        Parent2 !
            {r2,
                httpc:request(
                    post,
                    {Url, [], "application/json", Body},
                    [],
                    []
                )}
    end),
    R1 =
        receive
            {r1, X1} -> X1
        after 10000 -> {error, timeout}
        end,
    R2 =
        receive
            {r2, X2} -> X2
        after 10000 -> {error, timeout}
        end,
    %% Holder may still be running; abandon it (the linked exit is
    %% intentional via spawn, not spawn_link).
    exit(Holder, kill),
    receive
        {holder_done, _} -> ok
    after 0 -> ok
    end,
    Codes = [code_of(R) || R <- [R1, R2]],
    ct:log("codes=~p", [Codes]),
    ?assert(
        lists:member(429, Codes) orelse lists:member(504, Codes),
        io_lib:format("expected one of [429, 504] in ~p", [Codes])
    ),
    %% Cancel every in-flight ref so the model goes back to idle
    %% promptly. end_per_testcase polls idle but bounds the wait;
    %% explicit cancel avoids burning that whole budget.
    [erllama:cancel(R) || {R, _} <- erllama_inflight:all()],
    ok.

chat_cancel_on_disconnect_releases_slot(Cfg) ->
    %% Open a streaming chat, read the first chunk, then drop the
    %% connection. The handler's terminate/3 should fire and release
    %% the slot. After a short delay, a fresh request must be able to
    %% acquire the slot (no 504 / 429).
    Port = ?config(port, Cfg),
    Body = iolist_to_binary(
        json:encode(#{
            <<"model">> => <<"e2e-stub">>,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"max_tokens">> => 1000,
            <<"stream">> => true
        })
    ),
    %% Use raw gen_tcp to control the connection.
    {ok, Sock} = gen_tcp:connect(
        "127.0.0.1",
        Port,
        [binary, {active, false}, {packet, 0}]
    ),
    Req = [
        <<"POST /v1/chat/completions HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n">>,
        <<"\r\n">>,
        Body
    ],
    ok = gen_tcp:send(Sock, iolist_to_binary(Req)),
    %% Read at least the headers + one chunk to confirm streaming.
    %% CI runners can be slow to schedule the cowboy stream open +
    %% first model token (the full pipeline: load -> template ->
    %% queue -> admit -> infer -> first token). 2s was tight; bump
    %% to 15s so a heavily loaded runner doesn't false-fail before
    %% we even get to the cancel test.
    {ok, _Bytes} = gen_tcp:recv(Sock, 0, 15000),
    %% Drop the connection.
    gen_tcp:close(Sock),
    %% Now a fresh non-streaming request must land cleanly. The
    %% handler's terminate/3 races with this: it has to detect the
    %% TCP close, cancel the inference, and release the queue slot.
    %% On a slow CI runner that race can outlast a single sleep, so
    %% retry on the transient queue-busy responses (429, 504) up to
    %% a bounded budget. Anything else (or running out of retries)
    %% fails the assertion.
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body2 = json:encode(#{
        <<"model">> => <<"e2e-stub">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 2,
        <<"stream">> => false
    }),
    Code = post_until_slot_free(Url, Body2, 30, 200),
    ?assertEqual(200, Code).

%% Poll the chat endpoint until either the slot has been released
%% (200) or the budget runs out. Transient responses while the
%% disconnected request's terminate/3 is still in flight are 429
%% (pool_exhausted) or 504 (queue_timeout). Anything else stops the
%% polling and surfaces the actual status code for the assertion.
post_until_slot_free(_Url, _Body, 0, _BackoffMs) ->
    timeout;
post_until_slot_free(Url, Body, N, BackoffMs) ->
    case httpc:request(post, {Url, [], "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, _}} ->
            200;
        {ok, {{_, Code, _}, _, _}} when Code =:= 429; Code =:= 504 ->
            timer:sleep(BackoffMs),
            post_until_slot_free(Url, Body, N - 1, BackoffMs);
        {ok, {{_, Code, _}, _, _}} ->
            Code;
        {error, _} = E ->
            E
    end.

messages_streaming_emits_named_events(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"e2e-stub">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 4,
        <<"stream">> => true
    }),
    Resp = http_collect(Url, Body),
    ct:log(
        "messages SSE response (~p bytes): ~ts",
        [byte_size(Resp), Resp]
    ),
    %% Anthropic SSE has named events. No [DONE].
    ?assert(binary:match(Resp, <<"event: message_start">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: message_stop">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Resp, <<"data: [DONE]">>)).

embeddings_returns_vector(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/embeddings",
    Body = json:encode(#{
        <<"model">> => <<"e2e-stub">>,
        <<"input">> => <<"hello">>
    }),
    {ok, {{_, 200, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(RespBody)),
    [Entry] = maps:get(<<"data">>, Decoded),
    Vec = maps:get(<<"embedding">>, Entry),
    ?assert(is_list(Vec)),
    ?assert(length(Vec) > 0),
    ?assert(lists:all(fun is_number/1, Vec)).

%%====================================================================
%% Helpers
%%====================================================================

%% POST a body to Url and accumulate the full response body. Used for
%% SSE streams: the stub backend never produces eog so the stream
%% finishes when response_target is hit.
http_collect(Url, Body) ->
    %% httpc default is too tight for slow CI runners; bump both
    %% the connect and the total request timeout so a stub-backed
    %% stream that takes a few seconds to fully drain doesn't
    %% time out before we read the closing chunk.
    HttpOpts = [{timeout, 20000}, {connect_timeout, 5000}],
    {ok, {{_, 200, _}, _Headers, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, HttpOpts, []),
    list_to_binary(RespBody).

code_of({ok, {{_, Code, _}, _, _}}) -> Code;
code_of(_) -> 0.
