%%% End-to-end smoke for the erllama escript.
%%%
%%% Boots the server, drops a synthetic GGUF blob into the cache,
%%% then drives the escript via os:cmd against the live port. The
%%% suite asserts the table / progress output without leaning on
%%% inference.
-module(erllama_server_cli_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([
    help_prints_usage/1,
    pull_streams_status_lines/1,
    list_shows_table_with_pulled_model/1,
    show_returns_manifest_lines/1,
    rm_removes_manifest/1
]).

-define(T_UINT32, 4).
-define(T_STRING, 8).

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [
        help_prints_usage,
        pull_streams_status_lines,
        list_shows_table_with_pulled_model,
        show_returns_manifest_lines,
        rm_removes_manifest
    ].

init_per_suite(Config) ->
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    ok = filelib:ensure_path(Cache),
    Blob = filename:join(Cwd, "synthetic.gguf"),
    ok = file:write_file(Blob, synthetic_gguf()),
    application:set_env(erllama_server, model_cache_dir, Cache),
    Port = free_port(),
    application:set_env(erllama_server, port, Port),
    application:set_env(erllama_server, model_aliases, #{}),
    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    %% Build the escript on demand (rebar3 escriptize idempotent).
    Escript = build_escript(),
    [
        {cwd, Cwd},
        {blob, Blob},
        {port, Port},
        {escript, Escript},
        {started, Started}
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

help_prints_usage(Cfg) ->
    Out = run(Cfg, ["help"]),
    ?assert(string:str(Out, "erllama pull") > 0),
    ?assert(string:str(Out, "erllama list") > 0).

pull_streams_status_lines(Cfg) ->
    Spec = "file://" ++ ?config(blob, Cfg),
    %% Use the spec directly; the escript wraps it in a JSON body.
    Out = run(Cfg, ["pull", Spec]),
    ?assert(string:str(Out, "pulling manifest") > 0),
    ?assert(string:str(Out, "success") > 0).

list_shows_table_with_pulled_model(Cfg) ->
    {ok, _} = pull_one(<<"listed">>, <<"latest">>, Cfg),
    Out = run(Cfg, ["list"]),
    ?assert(string:str(Out, "NAME") > 0),
    ?assert(string:str(Out, "listed:latest") > 0).

show_returns_manifest_lines(Cfg) ->
    {ok, _} = pull_one(<<"shown-cli">>, <<"latest">>, Cfg),
    Out = run(Cfg, ["show", "shown-cli"]),
    ?assert(string:str(Out, "modelfile") > 0),
    ?assert(string:str(Out, "FROM") > 0).

rm_removes_manifest(Cfg) ->
    {ok, _} = pull_one(<<"to-be-removed">>, <<"latest">>, Cfg),
    Out = run(Cfg, ["rm", "to-be-removed"]),
    ?assert(string:str(Out, "removed to-be-removed") > 0),
    ?assertEqual({error, not_found}, erllama_server_models:get(<<"to-be-removed">>)).

%% =============================================================================
%% Helpers
%% =============================================================================

run(Cfg, Args) ->
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

pull_one(Name, Tag, Cfg) ->
    Blob = ?config(blob, Cfg),
    Spec = list_to_binary("file://" ++ Blob),
    erllama_server_models:pull(Spec, #{name => Name, tag => Tag}).

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

build_escript() ->
    %% Project root is two levels up from _build/test/logs.
    ProjectRoot = filename:dirname(filename:dirname(filename:dirname(?config(data_dir, [])))),
    %% Fallback: search up from cwd.
    Root = locate_root(),
    Bin = filename:join([Root, "_build", "default", "bin", "erllama"]),
    case filelib:is_regular(Bin) of
        true ->
            Bin;
        false ->
            os:cmd("cd " ++ ProjectRoot ++ " && rebar3 escriptize"),
            Bin
    end.

locate_root() ->
    {ok, Cwd} = file:get_cwd(),
    walk_up(Cwd).

walk_up("/") ->
    error(rebar_root_not_found);
walk_up(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true -> Dir;
        false -> walk_up(filename:dirname(Dir))
    end.

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

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_cli_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
