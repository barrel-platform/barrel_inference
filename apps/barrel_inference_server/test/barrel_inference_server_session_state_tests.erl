%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Unit tests for the per-session committed token-id store and the
%% record/4 assembly guard that anchors the byte-exact continuation
%% path (barrel_inference 0.8 `generated' ids).
-module(barrel_inference_server_session_state_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, <<"m">>).
-define(S, <<"sess">>).

session_state_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun put_get_roundtrip/0,
        fun get_missing/0,
        fun delete_removes/0,
        fun record_stores_when_count_matches/0,
        fun record_skips_on_count_mismatch/0,
        fun record_skips_without_generated/0,
        fun record_skips_empty_prompt/0,
        fun record_empty_generated_kept/0
    ]}.

setup() ->
    {ok, Pid} = barrel_inference_server_session_state:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid).

put_get_roundtrip() ->
    ok = barrel_inference_server_session_state:put(?M, ?S, [1, 2, 3]),
    ?assertEqual({ok, [1, 2, 3]}, barrel_inference_server_session_state:get(?M, ?S)).

get_missing() ->
    ?assertEqual(not_found, barrel_inference_server_session_state:get(?M, <<"nope">>)).

delete_removes() ->
    ok = barrel_inference_server_session_state:put(?M, ?S, [1, 2]),
    ok = barrel_inference_server_session_state:delete(?M, ?S),
    ?assertEqual(not_found, barrel_inference_server_session_state:get(?M, ?S)).

%% Prompt ++ generated is stored when its length agrees with the
%% engine's reported committed_tokens count.
record_stores_when_count_matches() ->
    Prompt = [10, 11, 12],
    Stats = #{generated => [20, 21], committed_tokens => 5},
    ok = barrel_inference_server_session_state:record(?M, ?S, Prompt, Stats),
    ?assertEqual({ok, [10, 11, 12, 20, 21]}, barrel_inference_server_session_state:get(?M, ?S)).

%% A disagreement between our assembled length and the engine's count
%% (truncation, stop-sequence trimming, ...) means the list cannot be
%% trusted as a continuation prefix - store nothing.
record_skips_on_count_mismatch() ->
    Prompt = [10, 11, 12],
    Stats = #{generated => [20, 21], committed_tokens => 99},
    ok = barrel_inference_server_session_state:record(?M, ?S, Prompt, Stats),
    ?assertEqual(not_found, barrel_inference_server_session_state:get(?M, ?S)).

%% No `generated' ids (older engine / non-continuation path): nothing
%% to anchor on, so store nothing.
record_skips_without_generated() ->
    ok = barrel_inference_server_session_state:record(?M, ?S, [10, 11], #{committed_tokens => 2}),
    ?assertEqual(not_found, barrel_inference_server_session_state:get(?M, ?S)).

%% Prompt tokens were not captured: store nothing.
record_skips_empty_prompt() ->
    Stats = #{generated => [20, 21], committed_tokens => 2},
    ok = barrel_inference_server_session_state:record(?M, ?S, [], Stats),
    ?assertEqual(not_found, barrel_inference_server_session_state:get(?M, ?S)).

%% A turn that generated nothing still commits its prompt; the list is
%% just the prompt and is kept when the count agrees.
record_empty_generated_kept() ->
    Prompt = [10, 11, 12],
    Stats = #{generated => [], committed_tokens => 3},
    ok = barrel_inference_server_session_state:record(?M, ?S, Prompt, Stats),
    ?assertEqual({ok, [10, 11, 12]}, barrel_inference_server_session_state:get(?M, ?S)).
