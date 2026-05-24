%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Unit tests for the Part 3 translate additions: Anthropic
%% `disable_parallel_tool_use' parsing and the non-streaming OpenAI
%% chat tool_calls response builder.
-module(barrel_inference_server_translate_tools_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_inference_server.hrl").

base_body(ToolChoice) ->
    Body = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    },
    case ToolChoice of
        undefined -> Body;
        _ -> Body#{<<"tool_choice">> => ToolChoice}
    end.

%% =============================================================================
%% Anthropic disable_parallel_tool_use -> parallel_tool_calls
%% =============================================================================

anthropic_disable_parallel_sets_false_test() ->
    Body = base_body(#{<<"type">> => <<"auto">>, <<"disable_parallel_tool_use">> => true}),
    {ok, R} = barrel_inference_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(false, R#barrel_inference_request.parallel_tool_calls).

anthropic_default_parallel_true_test() ->
    {ok, R} = barrel_inference_server_translate:anthropic_messages_to_internal(
        base_body(undefined)
    ),
    ?assertEqual(true, R#barrel_inference_request.parallel_tool_calls).

anthropic_disable_false_keeps_true_test() ->
    Body = base_body(#{<<"type">> => <<"auto">>, <<"disable_parallel_tool_use">> => false}),
    {ok, R} = barrel_inference_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(true, R#barrel_inference_request.parallel_tool_calls).

%% =============================================================================
%% internal_to_openai_chat_tool_calls_response/3 (N tool_calls)
%% =============================================================================

openai_tool_calls_response_emits_n_entries_test() ->
    Calls = [
        #{id => <<"call_a">>, name => <<"f1">>, input => #{<<"x">> => 1}},
        #{id => <<"call_b">>, name => <<"f2">>, input => #{<<"y">> => 2}}
    ],
    Stats = #{finish_reason => tool_call},
    Resp = barrel_inference_server_translate:internal_to_openai_chat_tool_calls_response(
        Calls, Stats, <<"m">>
    ),
    [Choice] = maps:get(<<"choices">>, Resp),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(null, maps:get(<<"content">>, Msg)),
    ToolCalls = maps:get(<<"tool_calls">>, Msg),
    ?assertEqual(2, length(ToolCalls)),
    [First, Second] = ToolCalls,
    ?assertEqual(0, maps:get(<<"index">>, First)),
    ?assertEqual(1, maps:get(<<"index">>, Second)),
    ?assertEqual(<<"call_a">>, maps:get(<<"id">>, First)),
    ?assertEqual(<<"f1">>, maps:get(<<"name">>, maps:get(<<"function">>, First))),
    %% Arguments are the JSON-encoded input object.
    Args = maps:get(<<"arguments">>, maps:get(<<"function">>, First)),
    ?assertEqual(#{<<"x">> => 1}, json:decode(Args)).
