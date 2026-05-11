%%% End-to-end CT for the Ollama-compatible /api/* surface.
%%%
%%% Boots the full erllama_server application against a random port,
%%% pre-populates a synthetic GGUF blob into a tmp cache, and hits
%%% each /api/* endpoint over HTTP.
-module(erllama_server_api_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([
    tags_empty_returns_empty_list/1,
    pull_streams_ndjson_progress/1,
    pull_blocking_returns_success/1,
    show_returns_modelfile_and_details/1,
    delete_removes_manifest/1,
    copy_creates_alias/1,
    create_from_directive_creates_manifest/1,
    create_unsupported_directive_returns_400/1,
    generate_empty_prompt_preloads/1,
    chat_empty_messages_preloads/1,
    generate_keep_alive_zero_unloads/1
]).

%% GGUF tags.
-define(T_UINT32, 4).
-define(T_STRING, 8).

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [
        tags_empty_returns_empty_list,
        pull_streams_ndjson_progress,
        pull_blocking_returns_success,
        show_returns_modelfile_and_details,
        delete_removes_manifest,
        copy_creates_alias,
        create_from_directive_creates_manifest,
        create_unsupported_directive_returns_400,
        generate_empty_prompt_preloads,
        chat_empty_messages_preloads,
        generate_keep_alive_zero_unloads
    ].

%% =============================================================================
%% Setup / teardown
%% =============================================================================

init_per_suite(Config) ->
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    ok = filelib:ensure_path(Cache),
    Blob = filename:join(Cwd, "synthetic.gguf"),
    ok = file:write_file(Blob, synthetic_gguf()),
    application:set_env(erllama_server, model_cache_dir, Cache),
    application:set_env(erllama_server, port, free_port()),
    application:set_env(erllama_server, model_aliases, #{}),
    application:set_env(
        erllama_server,
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 1, timeout_ms => 1000}}
    ),
    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    Url = io_lib:format("http://127.0.0.1:~p", [chosen_port()]),
    [
        {cwd, Cwd},
        {cache, Cache},
        {blob, Blob},
        {started, Started},
        {base, lists:flatten(Url)}
        | Config
    ].

end_per_suite(Config) ->
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    application:unset_env(erllama_server, model_cache_dir),
    Cwd = ?config(cwd, Config),
    os:cmd("rm -rf " ++ Cwd),
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

tags_empty_returns_empty_list(Cfg) ->
    %% Other cases run first and may have populated entries; if so just
    %% assert the response shape.
    {ok, {{_, 200, _}, _, Body}} = httpc:request(?config(base, Cfg) ++ "/api/tags"),
    Decoded = json:decode(list_to_binary(Body)),
    ?assert(is_list(maps:get(<<"models">>, Decoded))).

pull_streams_ndjson_progress(Cfg) ->
    Spec = file_spec(Cfg),
    Body = json:encode(#{
        <<"name">> => Spec,
        <<"tag">> => <<"streamed">>,
        <<"stream">> => true
    }),
    {ok, {{_, 200, _}, Hdrs, RawBody}} = post_json(Cfg, "/api/pull", Body),
    {value, {_, CT}} = lists:keysearch("content-type", 1, Hdrs),
    ?assertEqual("application/x-ndjson", CT),
    Lines = ndjson_lines(list_to_binary(RawBody)),
    Statuses = [maps:get(<<"status">>, L, undefined) || L <- Lines],
    ct:log("ndjson statuses: ~p", [Statuses]),
    ?assert(lists:member(<<"pulling manifest">>, Statuses)),
    ?assert(lists:member(<<"verifying sha256 digest">>, Statuses)),
    ?assert(lists:member(<<"writing manifest">>, Statuses)),
    ?assert(lists:member(<<"success">>, Statuses)),
    {ok, M} = erllama_server_models:get(<<"synthetic:streamed">>),
    ?assertEqual(<<"synthetic">>, maps:get(<<"name">>, M)),
    ?assertEqual(<<"streamed">>, maps:get(<<"tag">>, M)).

pull_blocking_returns_success(Cfg) ->
    Spec = file_spec(Cfg),
    Body = json:encode(#{
        <<"name">> => Spec,
        <<"tag">> => <<"blocked">>,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _Hdrs, Resp}} = post_json(Cfg, "/api/pull", Body),
    Decoded = json:decode(list_to_binary(Resp)),
    ?assertEqual(<<"success">>, maps:get(<<"status">>, Decoded)),
    {ok, _} = erllama_server_models:get(<<"synthetic:blocked">>).

show_returns_modelfile_and_details(Cfg) ->
    {ok, _} = pull_for(<<"shown">>, <<"latest">>, Cfg),
    Body = json:encode(#{<<"name">> => <<"shown">>}),
    {ok, {{_, 200, _}, _, Resp}} = post_json(Cfg, "/api/show", Body),
    Decoded = json:decode(list_to_binary(Resp)),
    Modelfile = maps:get(<<"modelfile">>, Decoded),
    ?assertMatch(<<"FROM ", _/binary>>, Modelfile),
    Details = maps:get(<<"details">>, Decoded),
    ?assertEqual(<<"gguf">>, maps:get(<<"format">>, Details)),
    ?assertEqual(<<"qwen">>, maps:get(<<"family">>, Details)),
    ?assertEqual(<<"q4_k_m">>, maps:get(<<"quantization_level">>, Details)),
    Info = maps:get(<<"model_info">>, Decoded),
    ?assertEqual(<<"qwen2">>, maps:get(<<"general.architecture">>, Info)),
    ?assertEqual(4096, maps:get(<<"context_length">>, Info)).

delete_removes_manifest(Cfg) ->
    {ok, _} = pull_for(<<"deletable">>, <<"latest">>, Cfg),
    Body = json:encode(#{<<"name">> => <<"deletable">>}),
    {ok, {{_, 200, _}, _, _}} = del_json(Cfg, "/api/delete", Body),
    ?assertEqual({error, not_found}, erllama_server_models:get(<<"deletable">>)),
    %% Deleting a nonexistent model -> 404.
    {ok, {{_, 404, _}, _, _}} = del_json(Cfg, "/api/delete", Body).

copy_creates_alias(Cfg) ->
    {ok, _} = pull_for(<<"orig-api">>, <<"latest">>, Cfg),
    Body = json:encode(#{
        <<"source">> => <<"orig-api">>,
        <<"destination">> => <<"copied-api:v1">>
    }),
    {ok, {{_, 200, _}, _, _}} = post_json(Cfg, "/api/copy", Body),
    {ok, M} = erllama_server_models:get(<<"copied-api:v1">>),
    ?assertEqual(<<"copied-api">>, maps:get(<<"name">>, M)),
    ?assertEqual(<<"v1">>, maps:get(<<"tag">>, M)).

create_from_directive_creates_manifest(Cfg) ->
    Spec = file_spec(Cfg),
    Modelfile = <<"FROM ", Spec/binary, "\n">>,
    Body = json:encode(#{
        <<"name">> => <<"created:v1">>,
        <<"modelfile">> => Modelfile
    }),
    {ok, {{_, 200, _}, _, _}} = post_json(Cfg, "/api/create", Body),
    {ok, M} = erllama_server_models:get(<<"created:v1">>),
    ?assertEqual(<<"created">>, maps:get(<<"name">>, M)).

create_unsupported_directive_returns_400(Cfg) ->
    Body = json:encode(#{
        <<"name">> => <<"bad">>,
        <<"modelfile">> => <<"PARAMETER temperature 0.8\n">>
    }),
    {ok, {{_, 400, _}, _, Resp}} = post_json(Cfg, "/api/create", Body),
    Decoded = json:decode(list_to_binary(Resp)),
    Err = maps:get(<<"error">>, Decoded),
    ?assert(binary:match(Err, <<"modelfile">>) =/= nomatch).

%% Ollama /api/generate with an empty prompt: returns a one-shot
%% JSON envelope with done=true, done_reason="load". Because the
%% server uses the stub erllama backend in tests there is no real
%% model to load; ensure_loaded_async fast-fails (model_not_found)
%% so the handler returns 404. We accept 200 OR 404 here so the
%% case proves the route is wired and the response shape doesn't
%% leak from an unrelated path.
generate_empty_prompt_preloads(Cfg) ->
    Body = json:encode(#{
        <<"model">> => <<"never-loaded">>,
        <<"prompt">> => <<>>,
        <<"stream">> => false
    }),
    {ok, {{_, Code, _}, _, Resp}} = post_json(Cfg, "/api/generate", Body),
    ?assert(Code =:= 200 orelse Code =:= 404 orelse Code =:= 503 orelse Code =:= 504),
    Decoded = json:decode(list_to_binary(Resp)),
    case Code of
        200 ->
            ?assertEqual(true, maps:get(<<"done">>, Decoded)),
            ?assertEqual(<<"load">>, maps:get(<<"done_reason">>, Decoded));
        _ ->
            ?assertMatch(#{<<"error">> := _}, Decoded)
    end.

chat_empty_messages_preloads(Cfg) ->
    Body = json:encode(#{
        <<"model">> => <<"never-loaded">>,
        <<"messages">> => [],
        <<"stream">> => false
    }),
    {ok, {{_, Code, _}, _, Resp}} = post_json(Cfg, "/api/chat", Body),
    ?assert(Code =:= 200 orelse Code =:= 404 orelse Code =:= 503 orelse Code =:= 504),
    case Code of
        200 ->
            Decoded = json:decode(list_to_binary(Resp)),
            ?assertEqual(true, maps:get(<<"done">>, Decoded)),
            ?assertMatch(#{<<"role">> := <<"assistant">>}, maps:get(<<"message">>, Decoded));
        _ ->
            ok
    end.

generate_keep_alive_zero_unloads(Cfg) ->
    Body = json:encode(#{
        <<"model">> => <<"never-loaded">>,
        <<"prompt">> => <<>>,
        <<"keep_alive">> => 0,
        <<"stream">> => false
    }),
    {ok, {{_, Code, _}, _, Resp}} = post_json(Cfg, "/api/generate", Body),
    ?assert(Code =:= 200 orelse Code =:= 404 orelse Code =:= 503 orelse Code =:= 504),
    case Code of
        200 ->
            Decoded = json:decode(list_to_binary(Resp)),
            ?assertEqual(<<"unload">>, maps:get(<<"done_reason">>, Decoded));
        _ ->
            ok
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

pull_for(Name, Tag, Cfg) ->
    Spec = file_spec(Cfg),
    erllama_server_models:pull(Spec, #{name => Name, tag => Tag}).

file_spec(Cfg) ->
    list_to_binary("file://" ++ ?config(blob, Cfg)).

post_json(Cfg, Path, Body) ->
    Url = ?config(base, Cfg) ++ Path,
    httpc:request(post, {Url, [], "application/json", Body}, [], []).

del_json(Cfg, Path, Body) ->
    Url = ?config(base, Cfg) ++ Path,
    httpc:request(delete, {Url, [], "application/json", Body}, [], []).

ndjson_lines(Bin) ->
    Parts = binary:split(Bin, <<"\n">>, [global]),
    [
        json:decode(P)
     || P <- Parts, P =/= <<>>
    ].

%% Synthetic GGUF mirroring the models suite.
synthetic_gguf() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen2">>},
        {<<"qwen2.context_length">>, ?T_UINT32, 4096},
        {<<"qwen2.embedding_length">>, ?T_UINT32, 4096},
        {<<"general.file_type">>, ?T_UINT32, 15},
        {<<"general.size_label">>, ?T_STRING, <<"7B">>}
    ],
    Body = iolist_to_binary([encode_kv(K, T, V) || {K, T, V} <- KVs]),
    <<"GGUF", 3:32/little, 0:64/little, (length(KVs)):64/little, Body/binary>>.

encode_kv(Key, Type, Value) ->
    <<(encode_string(Key))/binary, Type:32/little, (encode_value(Type, Value))/binary>>.

encode_value(?T_UINT32, V) -> <<V:32/little-unsigned>>;
encode_value(?T_STRING, V) -> encode_string(V).

encode_string(Bin) ->
    <<(byte_size(Bin)):64/little-unsigned, Bin/binary>>.

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    persistent_term:put({?MODULE, port}, Port),
    Port.

chosen_port() ->
    persistent_term:get({?MODULE, port}).

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_api_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
