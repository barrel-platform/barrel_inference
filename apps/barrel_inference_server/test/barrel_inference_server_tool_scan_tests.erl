%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Unit tests for the streaming tool-call text scanner.
-module(barrel_inference_server_tool_scan_tests).

-include_lib("eunit/include/eunit.hrl").

new() ->
    barrel_inference_server_tool_scan:new(#{
        start => <<"<tool_call>">>,
        'end' => <<"</tool_call>">>,
        format => barrel_inference_server_tool_format_qwen_xml,
        tool_names => [<<"get_weather">>, <<"search">>]
    }).

%% Feed the whole text in one chunk, then finish; return the flat emit list.
run(Text) ->
    {E1, S1} = barrel_inference_server_tool_scan:feed(new(), Text),
    {E2, _} = barrel_inference_server_tool_scan:finish(S1),
    E1 ++ E2.

%% Feed text split into single-byte chunks (stress the streaming holdback).
run_split(Text) ->
    {Rev, S} =
        lists:foldl(
            fun(<<C>>, {Acc, St}) ->
                {E, St1} = barrel_inference_server_tool_scan:feed(St, <<C>>),
                {lists:reverse(E) ++ Acc, St1}
            end,
            {[], new()},
            [<<C>> || <<C>> <= Text]
        ),
    {E, _} = barrel_inference_server_tool_scan:finish(S),
    lists:reverse(Rev) ++ E.

tools(Emits) -> [C || {tool, C} <- Emits].
text(Emits) -> iolist_to_binary([T || {text, T} <- Emits]).

%% =============================================================================

marker_one_chunk_test() ->
    E = run(
        <<"<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>">>
    ),
    ?assertMatch(
        [#{name := <<"get_weather">>, arguments := #{<<"city">> := <<"Paris">>}}], tools(E)
    ),
    ?assertEqual(<<>>, text(E)).

marker_split_across_chunks_test() ->
    E = run_split(
        <<"<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}</tool_call>">>
    ),
    ?assertMatch([#{name := <<"get_weather">>}], tools(E)).

surrounding_prose_kept_as_text_test() ->
    E = run(
        <<"Sure, let me check.<tool_call>{\"name\":\"get_weather\",\"arguments\":{}}</tool_call>">>
    ),
    ?assertMatch([#{name := <<"get_weather">>}], tools(E)),
    ?assertEqual(<<"Sure, let me check.">>, text(E)).

json_wrapper_tolerated_test() ->
    E = run(<<"<json>{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Lyon\"}}</json>">>),
    ?assertMatch(
        [#{name := <<"get_weather">>, arguments := #{<<"city">> := <<"Lyon">>}}], tools(E)
    ).

bare_json_tolerated_test() ->
    E = run(<<"{\"name\":\"search\",\"arguments\":{\"q\":\"erlang\"}}">>),
    ?assertMatch([#{name := <<"search">>}], tools(E)).

unknown_name_is_text_test() ->
    Bin = <<"{\"name\":\"not_a_tool\",\"arguments\":{}}">>,
    E = run(Bin),
    ?assertEqual([], tools(E)),
    ?assertEqual(Bin, text(E)).

args_not_object_is_text_test() ->
    Bin = <<"{\"name\":\"get_weather\",\"arguments\":\"oops\"}">>,
    E = run(Bin),
    ?assertEqual([], tools(E)),
    ?assertEqual(Bin, text(E)).

missing_required_still_emitted_test() ->
    %% Lenient (Ollama-style): known tool + args object, even with a missing
    %% required key, is still a tool call (schema enforcement is grammar's job).
    E = run(<<"<tool_call>{\"name\":\"get_weather\",\"arguments\":{}}</tool_call>">>),
    ?assertMatch([#{name := <<"get_weather">>, arguments := #{}}], tools(E)).

two_calls_parallel_test() ->
    E = run(
        <<"<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"A\"}}</tool_call>",
            "<tool_call>{\"name\":\"search\",\"arguments\":{\"q\":\"b\"}}</tool_call>">>
    ),
    ?assertMatch(
        [#{name := <<"get_weather">>}, #{name := <<"search">>}],
        tools(E)
    ).

plain_text_no_call_test() ->
    Bin = <<"Just a normal answer with no tool call at all.">>,
    E = run(Bin),
    ?assertEqual([], tools(E)),
    ?assertEqual(Bin, text(E)).

partial_marker_held_then_flushed_test() ->
    %% A trailing partial of the start marker with no JSON is flushed as text.
    {E1, S1} = barrel_inference_server_tool_scan:feed(new(), <<"hello <tool_c">>),
    {E2, _} = barrel_inference_server_tool_scan:finish(S1),
    All = E1 ++ E2,
    ?assertEqual([], tools(All)),
    ?assertEqual(<<"hello <tool_c">>, text(All)).

buffer_overflow_flushes_as_text_test() ->
    %% A lone `{' followed by a huge non-JSON-closing run must not buffer
    %% unboundedly; it is flushed as text.
    Big = binary:copy(<<"x">>, 20000),
    Bin = <<"{", Big/binary>>,
    E = run(Bin),
    ?assertEqual([], tools(E)),
    ?assertEqual(Bin, text(E)).
