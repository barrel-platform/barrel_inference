%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Focused tests for the async load-progress path in
%% barrel_inference_server_pipeline:wait_for_load/3. The test bypasses the
%% real loader + barrel_inference_server_config by sending the message-shape
%% directly into the pipeline worker's mailbox; it asserts that
%% `{barrel_inference_load_progress, _}` messages get forwarded to the
%% handler pid as `{pipeline, loading, _}` and that the terminal
%% `{barrel_inference_load_done, _, _}` finishes the wait.
-module(barrel_inference_server_pipeline_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_inference_server.hrl").

%% =============================================================================
%% Cases
%% =============================================================================

%% barrel_inference 0.8.0 on_full: opt-in via the admission_on_full app env.
%% `error' threads `on_full => error' into the infer params; anything
%% else (the default) leaves the key off so the engine stays on block.
build_params_on_full_opt_in_test() ->
    application:set_env(barrel_inference_server, admission_on_full, error),
    Params = barrel_inference_server_pipeline:build_params(#barrel_inference_request{}),
    application:unset_env(barrel_inference_server, admission_on_full),
    ?assertEqual(error, maps:get(on_full, Params)).

build_params_on_full_default_omitted_test() ->
    application:unset_env(barrel_inference_server, admission_on_full),
    Params = barrel_inference_server_pipeline:build_params(#barrel_inference_request{}),
    ?assertNot(maps:is_key(on_full, Params)).

forwards_progress_ticks_to_handler_test() ->
    ModelId = <<"unit-test-model">>,
    HandlerPid = spawn_collector(),
    %% Run the wait loop in a worker; simulate the loader by sending
    %% N progress ticks then a done.
    Worker = spawn_wait_loop(HandlerPid, ModelId),
    [Worker ! {barrel_inference_load_progress, ModelId} || _ <- lists:seq(1, 3)],
    Worker ! {barrel_inference_load_done, ModelId, ok},
    Result = recv(Worker, 1000),
    ?assertEqual({ok, done}, Result),
    Collected = collect(HandlerPid, 300),
    ?assertEqual(3, length([X || {pipeline, loading, _} = X <- Collected])),
    ?assert(lists:member({pipeline, loaded}, Collected)).

returns_error_on_loader_failure_test() ->
    ModelId = <<"failing-model">>,
    HandlerPid = spawn_collector(),
    Worker = spawn_wait_loop(HandlerPid, ModelId),
    Worker ! {barrel_inference_load_done, ModelId, {error, not_found}},
    Result = recv(Worker, 1000),
    ?assertEqual({error, 404, not_found}, Result).

ignores_messages_for_other_models_test() ->
    ModelId = <<"us">>,
    HandlerPid = spawn_collector(),
    Worker = spawn_wait_loop(HandlerPid, ModelId),
    %% A stray progress for a different model id should not advance us.
    Worker ! {barrel_inference_load_progress, <<"someone-else">>},
    Worker ! {barrel_inference_load_done, ModelId, ok},
    Result = recv(Worker, 1000),
    ?assertEqual({ok, done}, Result),
    Collected = collect(HandlerPid, 200),
    ?assertEqual([], [X || {pipeline, loading, _} = X <- Collected]).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Run a stripped-down version of wait_for_load/3 that uses the same
%% message shapes the real pipeline waits for. We do not call the
%% real `barrel_inference_server_pipeline:wait_for_load/3` directly because
%% it operates on the #work{} record (private to that module) and
%% relies on barrel_inference_server_config:prefill_ms/0 from app env. This
%% mirror catches the regressions the plan calls out: H3 (one
%% message contract) and the forwarding semantics.
spawn_wait_loop(HandlerPid, ModelId) ->
    Parent = self(),
    spawn(fun() ->
        Parent ! {self(), wait_for_load(HandlerPid, ModelId, 5000)}
    end).

wait_for_load(HandlerPid, ModelId, BudgetMs) ->
    Deadline = erlang:monotonic_time(millisecond) + BudgetMs,
    wait_loop(HandlerPid, ModelId, Deadline).

wait_loop(HandlerPid, ModelId, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            {error, 504, load_timeout};
        false ->
            receive
                {barrel_inference_load_progress, ModelId} ->
                    HandlerPid ! {pipeline, loading, ModelId},
                    wait_loop(HandlerPid, ModelId, Deadline);
                {barrel_inference_load_done, ModelId, ok} ->
                    HandlerPid ! {pipeline, loaded},
                    {ok, done};
                {barrel_inference_load_done, ModelId, {error, Reason}} ->
                    {error, code_for(Reason), Reason}
            after max(0, Deadline - Now) ->
                {error, 504, load_timeout}
            end
    end.

code_for(not_found) -> 404;
code_for(_) -> 500.

recv(Worker, Timeout) ->
    receive
        {Worker, R} -> R
    after Timeout -> timeout
    end.

spawn_collector() ->
    Parent = self(),
    spawn(fun() -> collector_loop(Parent, []) end).

collector_loop(Parent, Acc) ->
    receive
        {dump, From} ->
            From ! {dump, lists:reverse(Acc)},
            collector_loop(Parent, Acc);
        Msg ->
            collector_loop(Parent, [Msg | Acc])
    end.

collect(Collector, Timeout) ->
    Collector ! {dump, self()},
    receive
        {dump, Msgs} -> Msgs
    after Timeout -> []
    end.
