%%% End-to-end CT suite against a real GGUF model. Mirrors erllama's
%%% own `erllama_real_model_SUITE` pattern: gated on `LLAMA_TEST_MODEL`
%%% and skipped when unset, so default `rebar3 ct` stays green
%%% without a model file on disk.
%%%
%%% Usage:
%%%
%%% ```
%%%   LLAMA_TEST_MODEL=/path/to/tinyllama-1.1b-q4_k_m.gguf rebar3 ct \
%%%       --suite=erllama_server_real_model_SUITE
%%% ```
%%%
%%% What it covers:
%%% - /v1/chat/completions streaming + non-streaming
%%% - /v1/messages streaming + non-streaming
%%% - /v1/embeddings (skipped if the model has no chat template OR
%%%   no embedding support)
%%% - /v1/models lists the real model
-module(erllama_server_real_model_SUITE).

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
    models_lists_real_model/1,
    chat_streaming_runs/1,
    chat_non_streaming_runs/1,
    messages_streaming_runs/1,
    messages_non_streaming_runs/1,
    embeddings_runs/1
]).

-define(MODEL_ENV, "LLAMA_TEST_MODEL").
-define(SHORT_PROMPT, <<"The quick brown fox">>).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [
        models_lists_real_model,
        chat_streaming_runs,
        chat_non_streaming_runs,
        messages_streaming_runs,
        messages_non_streaming_runs,
        embeddings_runs
    ].

%%====================================================================
%% Setup
%%====================================================================

init_per_suite(Config) ->
    case os:getenv(?MODEL_ENV) of
        false ->
            {skip, "set " ?MODEL_ENV " to a GGUF path to enable this suite"};
        "" ->
            {skip, "empty " ?MODEL_ENV};
        Path ->
            case filelib:is_regular(Path) of
                false ->
                    {skip, lists:flatten(io_lib:format("not a file: ~ts", [Path]))};
                true ->
                    start_app(Path, Config)
            end
    end.

start_app(Path, Config) ->
    Port = free_port(),
    application:set_env(erllama_server, port, Port),
    application:set_env(erllama_server, model_aliases, #{}),
    application:set_env(
        erllama_server,
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 4, timeout_ms => 60000}}
    ),
    application:set_env(erllama_server, model_load_policy, preloaded),
    application:set_env(erllama_server, prefill_timeout_ms, 120000),
    application:set_env(erllama_server, generation_idle_timeout_ms, 60000),
    application:set_env(erllama_server, max_total_ms, 240000),
    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    httpc:set_options([
        {max_sessions, 16},
        {max_keep_alive_length, 0},
        {pipeline_timeout, 0}
    ]),
    Dir = make_tmp_dir(),
    DiskSrv = list_to_atom(
        "real_disk_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, DiskSrvPid} = erllama_cache_disk_srv:start_link(DiskSrv, Dir),
    true = unlink(DiskSrvPid),
    ModelId = <<"real">>,
    {ok, _} = erllama:load_model(ModelId, model_config(Path, DiskSrv)),
    [
        {port, Port},
        {base, "http://127.0.0.1:" ++ integer_to_list(Port)},
        {model, ModelId},
        {disk_srv, DiskSrv},
        {dir, Dir},
        {started, Started}
        | Config
    ].

end_per_suite(Config) when is_list(Config) ->
    catch erllama:unload(?config(model, Config)),
    catch gen_server:stop(?config(disk_srv, Config)),
    rm_rf(?config(dir, Config)),
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    ok;
end_per_suite(_) ->
    ok.

end_per_testcase(_TC, Config) ->
    Model = ?config(model, Config),
    wait_for_idle(Model, 50),
    ok.

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_real_" ++
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

wait_for_idle(_, 0) ->
    timeout;
wait_for_idle(Model, N) ->
    case catch erllama_model:status(Model) of
        idle ->
            ok;
        _ ->
            timer:sleep(200),
            wait_for_idle(Model, N - 1)
    end.

model_config(Path, DiskSrv) ->
    Fp = file_sha256(Path),
    #{
        backend => erllama_model_llama,
        model_path => Path,
        model_opts => #{n_gpu_layers => 0},
        context_opts => #{n_ctx => 2048, n_batch => 512},
        tier_srv => DiskSrv,
        tier => disk,
        fingerprint => Fp,
        fingerprint_mode => safe,
        quant_type => f16,
        quant_bits => 16,
        ctx_params_hash => crypto:hash(sha256, term_to_binary({2048, 512})),
        context_size => 2048,
        policy => #{
            min_tokens => 16,
            cold_min_tokens => 16,
            cold_max_tokens => 4096,
            continued_interval => 64,
            boundary_trim_tokens => 8,
            boundary_align_tokens => 16,
            session_resume_wait_ms => 1000
        }
    }.

file_sha256(Path) ->
    {ok, Bin} = file:read_file(Path),
    crypto:hash(sha256, Bin).

%%====================================================================
%% Tests
%%====================================================================

models_lists_real_model(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/models",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    Ids = [maps:get(<<"id">>, M) || M <- maps:get(<<"data">>, Decoded)],
    ?assert(lists:member(<<"real">>, Ids)).

chat_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => true
    }),
    Resp = http_post(Url, Body),
    ?assert(binary:match(Resp, <<"data: [DONE]">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"chat.completion.chunk">>) =/= nomatch),
    %% At least one content chunk must have non-empty content. The
    %% real model produces real text tokens.
    Lines = binary:split(Resp, <<"\n">>, [global]),
    Content = [extract_content(L) || L <- Lines, has_content_delta(L)],
    ?assert(lists:any(fun(B) -> byte_size(B) > 0 end, Content)).

chat_non_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(Resp)),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assert(byte_size(maps:get(<<"content">>, Msg)) > 0).

messages_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => true
    }),
    Resp = http_post(Url, Body),
    ?assert(binary:match(Resp, <<"event: message_start">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: message_stop">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Resp, <<"data: [DONE]">>)).

messages_non_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(Resp)),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    [Block] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assert(byte_size(maps:get(<<"text">>, Block)) > 0).

embeddings_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/embeddings",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"input">> => ?SHORT_PROMPT
    }),
    case httpc:request(post, {Url, [], "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, Resp}} ->
            Decoded = json:decode(list_to_binary(Resp)),
            [Entry] = maps:get(<<"data">>, Decoded),
            Vec = maps:get(<<"embedding">>, Entry),
            ?assert(is_list(Vec)),
            ?assert(length(Vec) > 0);
        {ok, {{_, 501, _}, _, _}} ->
            {skip, "model has no embedding support"};
        {ok, {{_, Code, _}, _, ErrBody}} ->
            ct:fail({embeddings_failed, Code, ErrBody})
    end.

%%====================================================================
%% Helpers
%%====================================================================

http_post(Url, Body) ->
    {ok, {{_, 200, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    list_to_binary(RespBody).

has_content_delta(Line) ->
    binary:match(Line, <<"\"content\":">>) =/= nomatch andalso
        binary:match(Line, <<"data: ">>) =/= nomatch.

%% Crude extraction: pull the value of `"content": "..."` out of a
%% chat.completion.chunk JSON. Real test value is just "non-empty".
extract_content(Line) ->
    case
        re:run(
            Line,
            <<"\"content\":\"([^\"]*)\"">>,
            [{capture, all_but_first, binary}]
        )
    of
        {match, [V]} -> V;
        nomatch -> <<>>
    end.
