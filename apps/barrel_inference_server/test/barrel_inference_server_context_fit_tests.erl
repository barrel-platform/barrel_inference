%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Context-fitting: per-request num_ctx parsing, the prompt budget that
%% reserves generation headroom, and raw-prompt tail truncation.
-module(barrel_inference_server_context_fit_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_inference_server.hrl").

%% =============================================================================
%% Ollama options.num_ctx -> context_cap
%% =============================================================================

ollama_num_ctx_sets_context_cap_test() ->
    Body = #{
        <<"model">> => <<"m">>,
        <<"prompt">> => <<"hi">>,
        <<"options">> => #{<<"num_ctx">> => 2048}
    },
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(Body),
    ?assertEqual(2048, R#barrel_inference_request.context_cap).

ollama_num_ctx_absent_is_undefined_test() ->
    Body = #{<<"model">> => <<"m">>, <<"prompt">> => <<"hi">>},
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(Body),
    ?assertEqual(undefined, R#barrel_inference_request.context_cap).

openai_has_no_context_cap_test() ->
    Body = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    },
    {ok, R} = barrel_inference_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(undefined, R#barrel_inference_request.context_cap).

%% =============================================================================
%% prompt_budget/2 — reserve generation headroom (prompt + gen <= EffCtx)
%% =============================================================================

%% Small max_tokens: reserve exactly max_tokens, prompt gets the rest.
budget_reserves_small_max_tokens_test() ->
    ?assertEqual(4096 - 256, barrel_inference_server_pipeline:prompt_budget(4096, 256)).

%% max_tokens larger than half the window: reserve is capped at half.
budget_caps_reserve_at_half_test() ->
    ?assertEqual(4096 div 2, barrel_inference_server_pipeline:prompt_budget(4096, 100000)).

%% num_ctx / context smaller than max_tokens: generation budget alone
%% cannot exceed the window; prompt budget stays >= 1.
budget_when_ctx_smaller_than_max_tokens_test() ->
    B = barrel_inference_server_pipeline:prompt_budget(512, 4096),
    ?assert(B >= 1),
    ?assertEqual(512 div 2, B).

budget_floors_at_one_test() ->
    ?assert(barrel_inference_server_pipeline:prompt_budget(2, 4096) >= 1).

%% =============================================================================
%% keep_tail/2 — raw prompt truncation keeps the most-recent tokens
%% =============================================================================

keep_tail_truncates_to_last_n_test() ->
    ?assertEqual([3, 4, 5], barrel_inference_server_pipeline:keep_tail([1, 2, 3, 4, 5], 3)).

keep_tail_noop_when_within_limit_test() ->
    ?assertEqual([1, 2], barrel_inference_server_pipeline:keep_tail([1, 2], 5)).
