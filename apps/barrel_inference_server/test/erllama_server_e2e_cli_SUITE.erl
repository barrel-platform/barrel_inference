%%% End-to-end suite that drives the full registry + CLI lifecycle
%%% against a stub-backed daemon. Everything routes through the
%%% erllama escript at `_build/<profile>/bin/erllama` and the HTTP
%%% surface, so this is the closest we get to a real user session.
%%%
%%% The stub model backend (erllama_model_stub) produces phash2-based
%%% deterministic tokens, so we can drive `run` and `/api/generate`
%%% without a real GGUF, while still exercising the full pipeline:
%%% pull -> manifest -> registry-aware loader -> erllama:load_model
%%% -> streaming inference -> response framing.
-module(erllama_server_e2e_cli_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([
    cli_full_lifecycle/1,
    cli_run_streams_against_stub/1,
    api_generate_streams_against_stub/1,
    api_chat_streams_against_stub/1,
    api_generate_empty_prompt_preloads/1,
    api_chat_keep_alive_zero_unloads/1,
    api_chat_after_unload_reloads_cleanly/1,
    api_chat_truncates_old_messages_on_overflow/1,
    api_chat_400_when_single_message_overflows/1,
    api_embed_returns_vectors/1,
    api_embeddings_legacy_returns_embedding/1
]).

%% GGUF tags.
-define(T_UINT32, 4).
-define(T_STRING, 8).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [
        cli_full_lifecycle,
        cli_run_streams_against_stub,
        api_generate_streams_against_stub,
        api_chat_streams_against_stub,
        api_generate_empty_prompt_preloads,
        api_chat_keep_alive_zero_unloads,
        api_chat_after_unload_reloads_cleanly,
        api_chat_truncates_old_messages_on_overflow,
        api_chat_400_when_single_message_overflows,
        api_embed_returns_vectors,
        api_embeddings_legacy_returns_embedding
    ].

%%====================================================================
%% Setup / teardown
%%====================================================================

init_per_suite(Config) ->
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    ok = filelib:ensure_path(Cache),
    Blob = filename:join(Cwd, "synthetic.gguf"),
    ok = file:write_file(Blob, synthetic_gguf()),

    Port = free_port(),
    application:set_env(erllama_server, model_cache_dir, Cache),
    application:set_env(erllama_server, port, Port),
    application:set_env(erllama_server, model_aliases, #{}),
    application:set_env(
        erllama_server,
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 4, timeout_ms => 5000}}
    ),
    application:set_env(erllama_server, model_load_policy, on_demand),
    %% Use the stub backend so the synthetic GGUF blob is loadable.
    application:set_env(erllama_server, model_backend, erllama_model_stub),
    application:set_env(erllama_server, max_context_size, 1024),
    %% Models stay loaded for the duration of the suite (matches the
    %% server default). Tests that need explicit unload pass
    %% keep_alive: 0 in the request body.
    application:set_env(erllama_server, keep_alive_default_ms, 300000),

    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    Base = "http://127.0.0.1:" ++ integer_to_list(Port),
    Escript = locate_escript(),
    [
        {cwd, Cwd},
        {cache, Cache},
        {blob, Blob},
        {port, Port},
        {base, Base},
        {escript, Escript},
        {started, Started}
        | Config
    ].

end_per_suite(Config) ->
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    application:unset_env(erllama_server, model_cache_dir),
    application:unset_env(erllama_server, model_backend),
    application:unset_env(erllama_server, max_context_size),
    application:unset_env(erllama_server, keep_alive_default_ms),
    os:cmd("rm -rf " ++ ?config(cwd, Config)),
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% pull (CLI) -> list (CLI) -> show (CLI) -> copy (CLI) -> rm (CLI).
cli_full_lifecycle(Cfg) ->
    Spec = file_spec(Cfg),

    %% Pull.
    PullOut = run_cli(Cfg, ["pull", Spec]),
    ?assert(string:str(PullOut, "success") > 0),
    ?assertMatch({ok, _}, erllama_server_models:get(<<"synthetic">>)),

    %% List shows the pulled model.
    ListOut = run_cli(Cfg, ["list"]),
    ?assert(string:str(ListOut, "synthetic:latest") > 0),

    %% Show prints the modelfile.
    ShowOut = run_cli(Cfg, ["show", "synthetic"]),
    ?assert(string:str(ShowOut, "modelfile") > 0),
    ?assert(string:str(ShowOut, "FROM") > 0),

    %% Copy creates an alias under a new name:tag.
    CopyOut = run_cli(Cfg, ["copy", "synthetic", "alias-cli:v1"]),
    ?assert(string:str(CopyOut, "copied") > 0),
    {ok, Alias} = erllama_server_models:get(<<"alias-cli:v1">>),
    ?assertEqual(<<"alias-cli">>, maps:get(<<"name">>, Alias)),

    %% List shows both.
    ListOut2 = run_cli(Cfg, ["list"]),
    ?assert(string:str(ListOut2, "synthetic:latest") > 0),
    ?assert(string:str(ListOut2, "alias-cli:v1") > 0),

    %% rm cleans up.
    _ = run_cli(Cfg, ["rm", "synthetic"]),
    _ = run_cli(Cfg, ["rm", "alias-cli:v1"]),
    ?assertEqual({error, not_found}, erllama_server_models:get(<<"synthetic">>)),
    ?assertEqual({error, not_found}, erllama_server_models:get(<<"alias-cli:v1">>)).

%% CLI `run` against a stub-backed model: pull then run, expect non-empty output.
cli_run_streams_against_stub(Cfg) ->
    Spec = file_spec(Cfg),
    {ok, _} = erllama_server_models:pull(Spec, #{name => <<"runtest">>, tag => <<"latest">>}),
    Out = run_cli(Cfg, ["run", "runtest:latest", "hi"]),
    %% Stub backend emits deterministic phash2-derived tokens. The
    %% test asserts non-empty output and absence of error markers.
    ?assert(length(Out) > 0),
    ?assertEqual(0, string:str(Out, "run failed")),
    ?assertEqual(0, string:str(Out, "error:")).

%% Ollama /api/generate streaming against the stub.
api_generate_streams_against_stub(Cfg) ->
    {ok, _} = pull_for(<<"gen-stream">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"gen-stream:latest">>,
        <<"prompt">> => <<"hi">>,
        <<"stream">> => true,
        <<"options">> => #{<<"num_predict">> => 8}
    }),
    {ok, {{_, 200, _}, Hdrs, Raw}} = post_json(Cfg, "/api/generate", Body),
    {value, {_, CT}} = lists:keysearch("content-type", 1, Hdrs),
    ?assertEqual("application/x-ndjson", CT),
    Lines = ndjson_lines(list_to_binary(Raw)),
    ?assert(length(Lines) >= 2),
    Final = lists:last(Lines),
    ?assertEqual(true, maps:get(<<"done">>, Final)),
    ?assert(is_binary(maps:get(<<"done_reason">>, Final))),
    ?assert(maps:get(<<"eval_count">>, Final) >= 1),
    ?assert(is_integer(maps:get(<<"total_duration">>, Final))).

%% Ollama /api/chat streaming against the stub.
api_chat_streams_against_stub(Cfg) ->
    {ok, _} = pull_for(<<"chat-stream">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"chat-stream:latest">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true,
        <<"options">> => #{<<"num_predict">> => 6}
    }),
    {ok, {{_, 200, _}, _, Raw}} = post_json(Cfg, "/api/chat", Body),
    Lines = ndjson_lines(list_to_binary(Raw)),
    ?assert(length(Lines) >= 2),
    %% Each non-final chunk has a `message` envelope.
    [First | _] = Lines,
    ?assertMatch(
        #{<<"role">> := <<"assistant">>},
        maps:get(<<"message">>, First)
    ),
    Final = lists:last(Lines),
    ?assertEqual(true, maps:get(<<"done">>, Final)).

%% Ollama /api/generate preload: empty prompt returns one-shot
%% {done:true, done_reason:"load"} JSON envelope.
api_generate_empty_prompt_preloads(Cfg) ->
    {ok, _} = pull_for(<<"preload-1">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"preload-1:latest">>,
        <<"prompt">> => <<>>,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Raw}} = post_json(Cfg, "/api/generate", Body),
    Resp = json:decode(list_to_binary(Raw)),
    ?assertEqual(true, maps:get(<<"done">>, Resp)),
    ?assertEqual(<<"load">>, maps:get(<<"done_reason">>, Resp)),
    ?assertEqual(<<>>, maps:get(<<"response">>, Resp)).

%% Ollama /api/embed against the stub: array of vectors + timings.
api_embed_returns_vectors(Cfg) ->
    {ok, _} = pull_for(<<"embed-1">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"embed-1:latest">>,
        <<"input">> => [<<"a">>, <<"b">>]
    }),
    {ok, {{_, 200, _}, _, Raw}} = post_json(Cfg, "/api/embed", Body),
    R = json:decode(list_to_binary(Raw)),
    Vecs = maps:get(<<"embeddings">>, R),
    ?assertEqual(2, length(Vecs)),
    [V | _] = Vecs,
    ?assert(is_list(V)),
    ?assert(length(V) > 0).

%% Legacy /api/embeddings: one prompt, one vector.
api_embeddings_legacy_returns_embedding(Cfg) ->
    {ok, _} = pull_for(<<"embed-legacy">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"embed-legacy:latest">>,
        <<"prompt">> => <<"hello">>
    }),
    {ok, {{_, 200, _}, _, Raw}} = post_json(Cfg, "/api/embeddings", Body),
    R = json:decode(list_to_binary(Raw)),
    V = maps:get(<<"embedding">>, R),
    ?assert(is_list(V)),
    ?assert(length(V) > 0).

%% keep_alive: 0 on a preload request emits done_reason: "unload".
api_chat_keep_alive_zero_unloads(Cfg) ->
    {ok, _} = pull_for(<<"unload-1">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"model">> => <<"unload-1:latest">>,
        <<"messages">> => [],
        <<"keep_alive">> => 0,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Raw}} = post_json(Cfg, "/api/chat", Body),
    Resp = json:decode(list_to_binary(Raw)),
    ?assertEqual(true, maps:get(<<"done">>, Resp)),
    ?assertEqual(<<"unload">>, maps:get(<<"done_reason">>, Resp)).

%% Regression for the stale-loader bug. Load the model, unload it via
%% keep_alive: 0, then issue a real chat. Before the loader monitored
%% the underlying gen_statem the next request would crash with
%% {noproc, {erllama_model, not_found, _}} because the loader was
%% latched on `loaded`. After the fix, the loader has exited and the
%% next ensure_loaded creates a fresh loader that re-runs load_model.
%% Many short messages whose combined token count overflows context.
%% The pipeline should silently drop the oldest non-final messages
%% until it fits, then return 200. Mirrors Ollama's truncation
%% strategy (server/prompt.go).
api_chat_truncates_old_messages_on_overflow(Cfg) ->
    {ok, _} = pull_for(<<"trunc-1">>, <<"latest">>, Cfg),
    %% Stub tokenizer splits on " ", so each space-separated word is
    %% one token. With max_context_size=1024 in init_per_suite, we
    %% need to send ~1100+ tokens worth of messages to force truncation.
    BigContent = iolist_to_binary(lists:duplicate(150, <<"word ">>)),
    Messages =
        [
            #{<<"role">> => <<"user">>, <<"content">> => BigContent}
         || _ <- lists:seq(1, 10)
        ] ++ [#{<<"role">> => <<"user">>, <<"content">> => <<"final">>}],
    Body = json:encode(#{
        <<"model">> => <<"trunc-1:latest">>,
        <<"messages">> => Messages,
        <<"stream">> => false,
        <<"options">> => #{<<"num_predict">> => 2}
    }),
    {ok, {{_, Status, _}, _, Raw}} = post_json(Cfg, "/api/chat", Body),
    ?assertEqual(200, Status),
    Resp = json:decode(list_to_binary(Raw)),
    ?assertEqual(true, maps:get(<<"done">>, Resp)).

%% A single message whose tokens alone overflow context can't be
%% truncated. The pipeline must return 400 `context_overflow' rather
%% than 200 or 500 (NIF crash). 413 is reserved for HTTP body-byte
%% size per Anthropic / OpenAI conventions.
api_chat_400_when_single_message_overflows(Cfg) ->
    {ok, _} = pull_for(<<"trunc-2">>, <<"latest">>, Cfg),
    %% > 1024 tokens in one message (each space-separated word = 1 token).
    Huge = iolist_to_binary(lists:duplicate(1100, <<"x ">>)),
    Body = json:encode(#{
        <<"model">> => <<"trunc-2:latest">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Huge}],
        <<"stream">> => false
    }),
    {ok, {{_, Status, _}, _, _Raw}} = post_json(Cfg, "/api/chat", Body),
    ?assertEqual(400, Status).

api_chat_after_unload_reloads_cleanly(Cfg) ->
    {ok, _} = pull_for(<<"reload-1">>, <<"latest">>, Cfg),
    %% First: load + unload synchronously via keep_alive: 0.
    Unload = json:encode(#{
        <<"model">> => <<"reload-1:latest">>,
        <<"messages">> => [],
        <<"keep_alive">> => 0,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, _}} = post_json(Cfg, "/api/chat", Unload),
    %% Give the loader's model monitor a tick to fire and exit.
    timer:sleep(50),
    %% Then: real chat. Must NOT 500 with model_crashed / noproc.
    Chat = json:encode(#{
        <<"model">> => <<"reload-1:latest">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ],
        <<"keep_alive">> => 300000,
        <<"stream">> => false
    }),
    {ok, {{_, Status, _}, _, Raw}} = post_json(Cfg, "/api/chat", Chat),
    ?assertEqual(200, Status),
    Resp = json:decode(list_to_binary(Raw)),
    ?assertEqual(true, maps:get(<<"done">>, Resp)).

%%====================================================================
%% Helpers
%%====================================================================

run_cli(Cfg, Args) ->
    Escript = ?config(escript, Cfg),
    Port = ?config(port, Cfg),
    Env = "ERLLAMA_HOST=http://127.0.0.1:" ++ integer_to_list(Port),
    Cmd =
        Env ++ " " ++ Escript ++ " " ++
            string:join([shell_escape(A) || A <- Args], " ") ++ " 2>&1",
    os:cmd(Cmd).

shell_escape(S) ->
    "'" ++ lists:concat([escape_quote(C) || C <- S]) ++ "'".

escape_quote($') -> "'\\''";
escape_quote(C) -> [C].

pull_for(Name, Tag, Cfg) ->
    Spec = list_to_binary(file_spec(Cfg)),
    erllama_server_models:pull(Spec, #{name => Name, tag => Tag}).

file_spec(Cfg) ->
    "file://" ++ ?config(blob, Cfg).

post_json(Cfg, Path, Body) ->
    Url = ?config(base, Cfg) ++ Path,
    httpc:request(post, {Url, [], "application/json", Body}, [], []).

ndjson_lines(Bin) ->
    Parts = binary:split(Bin, <<"\n">>, [global]),
    [json:decode(P) || P <- Parts, P =/= <<>>].

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(Sock),
    gen_tcp:close(Sock),
    P.

locate_escript() ->
    Root = walk_up(),
    Bin = filename:join([Root, "_build", "default", "bin", "erllama"]),
    case filelib:is_regular(Bin) of
        true ->
            Bin;
        false ->
            os:cmd("cd " ++ Root ++ " && rebar3 escriptize"),
            Bin
    end.

walk_up() ->
    {ok, Cwd} = file:get_cwd(),
    walk_up_to_rebar(Cwd).

walk_up_to_rebar("/") ->
    error(rebar_root_not_found);
walk_up_to_rebar(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true -> Dir;
        false -> walk_up_to_rebar(filename:dirname(Dir))
    end.

synthetic_gguf() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen2">>},
        {<<"qwen2.context_length">>, ?T_UINT32, 1024},
        {<<"qwen2.embedding_length">>, ?T_UINT32, 1024},
        {<<"general.file_type">>, ?T_UINT32, 1},
        {<<"general.size_label">>, ?T_STRING, <<"stub">>}
    ],
    Body = iolist_to_binary([encode_kv(K, T, V) || {K, T, V} <- KVs]),
    <<"GGUF", 3:32/little, 0:64/little, (length(KVs)):64/little, Body/binary>>.

encode_kv(Key, Type, Value) ->
    <<(encode_string(Key))/binary, Type:32/little, (encode_value(Type, Value))/binary>>.

encode_value(?T_UINT32, V) -> <<V:32/little-unsigned>>;
encode_value(?T_STRING, V) -> encode_string(V).

encode_string(Bin) ->
    <<(byte_size(Bin)):64/little-unsigned, Bin/binary>>.

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_e2e_cli_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
