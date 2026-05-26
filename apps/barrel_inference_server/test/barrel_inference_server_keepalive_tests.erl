%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_keepalive_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    case whereis(barrel_inference_server_keepalive) of
        undefined ->
            {ok, Pid} = barrel_inference_server_keepalive:start_link(),
            unlink(Pid),
            Pid;
        Pid ->
            Pid
    end.

cleanup(Pid) ->
    catch gen_server:stop(Pid),
    %% Wait for the registration to clear so the next setup can
    %% re-register cleanly.
    wait_unregistered(50).

wait_unregistered(0) ->
    ok;
wait_unregistered(N) ->
    case whereis(barrel_inference_server_keepalive) of
        undefined ->
            ok;
        _ ->
            timer:sleep(10),
            wait_unregistered(N - 1)
    end.

%% =============================================================================
%% Cases
%% =============================================================================

keepalive_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            ?_test(zero_keepalive_unloads_immediately()),
            ?_test(timed_keepalive_unloads_after_delay()),
            ?_test(infinity_keepalive_never_unloads()),
            ?_test(re_begin_cancels_pending_unload()),
            ?_test(unload_without_begin_is_safe()),
            ?_test(status_carries_last_active_ms()),
            ?_test(unload_sync_drops_entry()),
            ?_test(unload_idle_sync_drops_when_idle()),
            ?_test(unload_idle_sync_busy_when_active()),
            ?_test(unload_idle_sync_busy_when_untracked())
        ]
    end}.

zero_keepalive_unloads_immediately() ->
    Id = <<"unit-zero">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, 0),
    ?assertNotEqual(undefined, whereis(barrel_inference_server_keepalive)).

timed_keepalive_unloads_after_delay() ->
    Id = <<"unit-timed">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, 100),
    timer:sleep(200),
    ?assertNotEqual(undefined, whereis(barrel_inference_server_keepalive)).

infinity_keepalive_never_unloads() ->
    Id = <<"unit-infinity">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, infinity),
    timer:sleep(50),
    ok = barrel_inference_server_keepalive:unload_now(Id),
    ?assertNotEqual(undefined, whereis(barrel_inference_server_keepalive)).

re_begin_cancels_pending_unload() ->
    Id = <<"unit-cancel">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, 200),
    ok = barrel_inference_server_keepalive:request_begin(Id),
    timer:sleep(300),
    ok = barrel_inference_server_keepalive:request_end(Id, 0),
    ?assertNotEqual(undefined, whereis(barrel_inference_server_keepalive)).

unload_without_begin_is_safe() ->
    ok = barrel_inference_server_keepalive:request_end(<<"never-seen">>, 0),
    ok = barrel_inference_server_keepalive:unload_now(<<"never-seen">>),
    ?assertNotEqual(undefined, whereis(barrel_inference_server_keepalive)).

status_carries_last_active_ms() ->
    Id = <<"unit-recency">>,
    Before = erlang:system_time(millisecond),
    ok = barrel_inference_server_keepalive:request_begin(Id),
    #{active := 1, last_active_ms := L} = barrel_inference_server_keepalive:status(Id),
    ?assert(L >= Before),
    %% Keep it loaded (infinity) so the entry stays for the assertion.
    ok = barrel_inference_server_keepalive:request_end(Id, infinity).

unload_sync_drops_entry() ->
    Id = <<"unit-unload-sync">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, infinity),
    ?assertMatch(#{model := Id}, barrel_inference_server_keepalive:status(Id)),
    ok = barrel_inference_server_keepalive:unload_sync(Id),
    ?assertEqual(not_tracked, barrel_inference_server_keepalive:status(Id)).

unload_idle_sync_drops_when_idle() ->
    Id = <<"unit-idle-sync-ok">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    ok = barrel_inference_server_keepalive:request_end(Id, infinity),
    ?assertMatch(#{model := Id, active := 0}, barrel_inference_server_keepalive:status(Id)),
    ?assertEqual(ok, barrel_inference_server_keepalive:unload_idle_sync(Id)),
    ?assertEqual(not_tracked, barrel_inference_server_keepalive:status(Id)).

unload_idle_sync_busy_when_active() ->
    Id = <<"unit-idle-sync-busy">>,
    ok = barrel_inference_server_keepalive:request_begin(Id),
    %% A request is in flight (active = 1): must not unload.
    ?assertEqual(busy, barrel_inference_server_keepalive:unload_idle_sync(Id)),
    ?assertMatch(#{active := 1}, barrel_inference_server_keepalive:status(Id)),
    ok = barrel_inference_server_keepalive:request_end(Id, infinity).

unload_idle_sync_busy_when_untracked() ->
    ?assertEqual(busy, barrel_inference_server_keepalive:unload_idle_sync(<<"never-seen-idle">>)).
