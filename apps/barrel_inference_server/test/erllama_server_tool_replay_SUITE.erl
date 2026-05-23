%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_tool_replay_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [
        put_and_get_round_trip,
        get_unknown_returns_not_found,
        delete_removes_entry,
        gc_evicts_expired,
        restart_replays_dets_into_ets
    ].

init_per_suite(Config) ->
    application:set_env(erllama_server, tool_replay_gc_interval_ms, 100000),
    application:set_env(erllama_server, tool_replay_ttl_ms, 30000),
    Config.

end_per_suite(_Config) ->
    application:unset_env(erllama_server, tool_replay_gc_interval_ms),
    application:unset_env(erllama_server, tool_replay_ttl_ms),
    application:unset_env(erllama_server, tool_replay_dir),
    ok.

init_per_testcase(_, Config) ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "erllama_replay_suite_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Dir),
    application:set_env(erllama_server, tool_replay_dir, Dir),
    %% The store relies on the config gen_server's persistent_term
    %% entries for ttl / gc interval. Seed them directly so the test
    %% doesn't need to spin the full supervisor tree.
    persistent_term:put({erllama_server_config, tool_replay_ttl_ms}, 30000),
    persistent_term:put({erllama_server_config, tool_replay_gc_interval_ms}, 100000),
    {ok, Pid} = erllama_server_tool_replay:start_link(),
    [{store, Pid}, {dir, Dir} | Config].

end_per_testcase(_, Config) ->
    Pid = ?config(store, Config),
    Dir = ?config(dir, Config),
    case is_process_alive(Pid) of
        true ->
            gen_server:stop(Pid, normal, 5000);
        false ->
            ok
    end,
    os:cmd("rm -rf " ++ Dir),
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

put_and_get_round_trip(_Config) ->
    ok = erllama_server_tool_replay:put(
        <<"toolu_1">>,
        <<"model-a">>,
        <<"<tool_call>{\"name\":\"f\"}</tool_call>">>,
        #{<<"name">> => <<"f">>}
    ),
    %% put/4 is async; sync via a synchronous gc call so the cast is
    %% guaranteed processed before the lookup.
    ok = sync(),
    ?assertEqual(
        {ok,
            {<<"model-a">>, <<"<tool_call>{\"name\":\"f\"}</tool_call>">>, #{<<"name">> => <<"f">>}}},
        erllama_server_tool_replay:get(<<"toolu_1">>)
    ).

get_unknown_returns_not_found(_Config) ->
    ?assertEqual(not_found, erllama_server_tool_replay:get(<<"toolu_does_not_exist">>)).

delete_removes_entry(_Config) ->
    ok = erllama_server_tool_replay:put(
        <<"toolu_d">>, <<"m">>, <<"bytes">>, #{<<"name">> => <<"x">>}
    ),
    ok = sync(),
    ?assertMatch({ok, _}, erllama_server_tool_replay:get(<<"toolu_d">>)),
    ok = erllama_server_tool_replay:delete(<<"toolu_d">>),
    ok = sync(),
    ?assertEqual(not_found, erllama_server_tool_replay:get(<<"toolu_d">>)).

gc_evicts_expired(_Config) ->
    %% Shrink the TTL so the put expires within the test's wall time.
    persistent_term:put({erllama_server_config, tool_replay_ttl_ms}, 50),
    ok = erllama_server_tool_replay:put(
        <<"toolu_exp">>, <<"m">>, <<"bytes">>, #{<<"name">> => <<"x">>}
    ),
    ok = sync(),
    timer:sleep(120),
    ok = erllama_server_tool_replay:gc(),
    ok = sync(),
    ?assertEqual(not_found, erllama_server_tool_replay:get(<<"toolu_exp">>)),
    %% Restore the longer TTL for the next case.
    persistent_term:put({erllama_server_config, tool_replay_ttl_ms}, 30000).

restart_replays_dets_into_ets(Config) ->
    Pid = ?config(store, Config),
    ok = erllama_server_tool_replay:put(
        <<"toolu_persist">>,
        <<"m">>,
        <<"persisted-bytes">>,
        #{<<"name">> => <<"y">>}
    ),
    ok = sync(),
    %% Stop the store cleanly; DETS sync + close happens in terminate/2.
    ok = gen_server:stop(Pid, normal, 5000),
    %% Re-open and confirm the row is back in ETS via the public get/1.
    {ok, _} = erllama_server_tool_replay:start_link(),
    ?assertMatch(
        {ok, {<<"m">>, <<"persisted-bytes">>, #{<<"name">> := <<"y">>}}},
        erllama_server_tool_replay:get(<<"toolu_persist">>)
    ).

%% Round-trip a manual `gc/0' cast and wait for the gen_server to
%% process it. Since put/delete/gc are all casts handled in order,
%% waiting on a gc reply guarantees the prior cast was processed too.
sync() ->
    erllama_server_tool_replay:gc(),
    %% gc is a cast; use a sync call (handle_call no-op) to flush the
    %% mailbox up to and past the gc.
    gen_server:call(erllama_server_tool_replay, ping),
    ok.
