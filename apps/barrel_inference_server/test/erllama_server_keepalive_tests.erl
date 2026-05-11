%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_keepalive_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    case whereis(erllama_server_keepalive) of
        undefined ->
            {ok, Pid} = erllama_server_keepalive:start_link(),
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
    case whereis(erllama_server_keepalive) of
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
            ?_test(unload_without_begin_is_safe())
        ]
    end}.

zero_keepalive_unloads_immediately() ->
    Id = <<"unit-zero">>,
    ok = erllama_server_keepalive:request_begin(Id),
    ok = erllama_server_keepalive:request_end(Id, 0),
    ?assertNotEqual(undefined, whereis(erllama_server_keepalive)).

timed_keepalive_unloads_after_delay() ->
    Id = <<"unit-timed">>,
    ok = erllama_server_keepalive:request_begin(Id),
    ok = erllama_server_keepalive:request_end(Id, 100),
    timer:sleep(200),
    ?assertNotEqual(undefined, whereis(erllama_server_keepalive)).

infinity_keepalive_never_unloads() ->
    Id = <<"unit-infinity">>,
    ok = erllama_server_keepalive:request_begin(Id),
    ok = erllama_server_keepalive:request_end(Id, infinity),
    timer:sleep(50),
    ok = erllama_server_keepalive:unload_now(Id),
    ?assertNotEqual(undefined, whereis(erllama_server_keepalive)).

re_begin_cancels_pending_unload() ->
    Id = <<"unit-cancel">>,
    ok = erllama_server_keepalive:request_begin(Id),
    ok = erllama_server_keepalive:request_end(Id, 200),
    ok = erllama_server_keepalive:request_begin(Id),
    timer:sleep(300),
    ok = erllama_server_keepalive:request_end(Id, 0),
    ?assertNotEqual(undefined, whereis(erllama_server_keepalive)).

unload_without_begin_is_safe() ->
    ok = erllama_server_keepalive:request_end(<<"never-seen">>, 0),
    ok = erllama_server_keepalive:unload_now(<<"never-seen">>),
    ?assertNotEqual(undefined, whereis(erllama_server_keepalive)).
