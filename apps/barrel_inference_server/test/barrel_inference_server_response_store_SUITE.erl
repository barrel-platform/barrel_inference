%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_response_store_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [
        put_and_get_round_trip,
        get_unknown_returns_not_found,
        delete_removes_entry,
        gc_evicts_expired
    ].

init_per_testcase(_, Config) ->
    %% The store reads ttl / gc interval off the config gen_server's
    %% persistent_term entries. Seed them directly so the test doesn't
    %% need the full supervisor tree.
    persistent_term:put({barrel_inference_server_config, responses_store_ttl_ms}, 30000),
    persistent_term:put({barrel_inference_server_config, responses_store_gc_interval_ms}, 100000),
    {ok, Pid} = barrel_inference_server_response_store:start_link(),
    [{store, Pid} | Config].

end_per_testcase(_, Config) ->
    Pid = ?config(store, Config),
    case is_process_alive(Pid) of
        true -> gen_server:stop(Pid, normal, 5000);
        false -> ok
    end,
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

put_and_get_round_trip(_Config) ->
    Msgs = [
        #{role => <<"user">>, content => <<"My name is Sam.">>},
        #{role => <<"assistant">>, content => <<"Nice to meet you, Sam.">>}
    ],
    ok = barrel_inference_server_response_store:put(<<"resp_1">>, <<"model-a">>, Msgs),
    ok = sync(),
    ?assertEqual(
        {ok, {<<"model-a">>, Msgs}},
        barrel_inference_server_response_store:get(<<"resp_1">>)
    ).

get_unknown_returns_not_found(_Config) ->
    ?assertEqual(not_found, barrel_inference_server_response_store:get(<<"resp_missing">>)).

delete_removes_entry(_Config) ->
    ok = barrel_inference_server_response_store:put(
        <<"resp_d">>, <<"m">>, [#{role => <<"user">>, content => <<"hi">>}]
    ),
    ok = sync(),
    ?assertMatch({ok, _}, barrel_inference_server_response_store:get(<<"resp_d">>)),
    ok = barrel_inference_server_response_store:delete(<<"resp_d">>),
    ok = sync(),
    ?assertEqual(not_found, barrel_inference_server_response_store:get(<<"resp_d">>)).

gc_evicts_expired(_Config) ->
    persistent_term:put({barrel_inference_server_config, responses_store_ttl_ms}, 50),
    ok = barrel_inference_server_response_store:put(
        <<"resp_exp">>, <<"m">>, [#{role => <<"user">>, content => <<"hi">>}]
    ),
    ok = sync(),
    timer:sleep(120),
    %% Lookup past the TTL already reports not_found...
    ?assertEqual(not_found, barrel_inference_server_response_store:get(<<"resp_exp">>)),
    %% ...and gc physically removes the row.
    ok = barrel_inference_server_response_store:gc(),
    ok = sync(),
    ?assertEqual(not_found, barrel_inference_server_response_store:get(<<"resp_exp">>)),
    persistent_term:put({barrel_inference_server_config, responses_store_ttl_ms}, 30000).

%% Round-trip a manual gc cast and a ping call to flush the mailbox:
%% put / delete / gc are casts handled in order, so a sync call after
%% them guarantees the prior cast was processed.
sync() ->
    barrel_inference_server_response_store:gc(),
    gen_server:call(barrel_inference_server_response_store, ping),
    ok.
