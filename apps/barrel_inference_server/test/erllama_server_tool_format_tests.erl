%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_tool_format_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QWEN, erllama_server_tool_format_qwen_xml).
-define(SPEC, #{module => ?QWEN}).

%% =============================================================================
%% qwen-xml parser
%% =============================================================================

qwen_xml_parses_canonical_test() ->
    Bin =
        <<"<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?QWEN:parse(Bin)
    ).

qwen_xml_parses_with_leading_whitespace_test() ->
    Bin = <<"<tool_call>\n  {\"name\":\"x\",\"arguments\":{}}  \n</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"x">>, arguments => #{}}},
        ?QWEN:parse(Bin)
    ).

qwen_xml_parses_hermes_string_arguments_test() ->
    %% Hermes-style: arguments is a JSON-encoded string rather than a
    %% JSON object. Seen on some Qwen2.5 fine-tunes.
    Bin =
        <<"<tool_call>{\"name\":\"f\",\"arguments\":\"{\\\"k\\\":1}\"}</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"k">> => 1}}},
        ?QWEN:parse(Bin)
    ).

qwen_xml_defaults_missing_arguments_to_empty_map_test() ->
    Bin = <<"<tool_call>{\"name\":\"f\"}</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?QWEN:parse(Bin)
    ).

qwen_xml_rejects_missing_markers_test() ->
    ?assertEqual({error, no_markers}, ?QWEN:parse(<<"{\"name\":\"f\"}">>)).

qwen_xml_rejects_invalid_json_test() ->
    ?assertMatch({error, _}, ?QWEN:parse(<<"<tool_call>{garbage</tool_call>">>)).

qwen_xml_rejects_payload_without_name_test() ->
    ?assertMatch(
        {error, _},
        ?QWEN:parse(<<"<tool_call>{\"arguments\":{}}</tool_call>">>)
    ).

%% =============================================================================
%% qwen-xml canonicaliser + round-trip
%% =============================================================================

qwen_xml_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?QWEN:canonicalise(Json),
    ?assertEqual({ok, Json}, ?QWEN:parse(Bin)).

qwen_xml_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?QWEN:canonicalise(Json),
    ?assertEqual({ok, Json}, ?QWEN:parse(Bin)).

qwen_xml_canonicalise_round_trip_nested_args_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?QWEN:canonicalise(Json),
    ?assertEqual({ok, Json}, ?QWEN:parse(Bin)).

%% =============================================================================
%% registry dispatch
%% =============================================================================

registry_parse_dispatches_to_module_test() ->
    Bin = <<"<tool_call>{\"name\":\"a\",\"arguments\":{}}</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        erllama_server_tool_format:parse(?SPEC, Bin)
    ).

registry_canonicalise_dispatches_to_module_test() ->
    Json = #{name => <<"a">>, arguments => #{}},
    Bin = erllama_server_tool_format:canonicalise(?SPEC, Json),
    ?assertEqual({ok, Json}, ?QWEN:parse(Bin)).

%% Lookup against a model id that has no manifest entry returns
%% not_found. Manifest-driven lookup is covered end-to-end in PR 5.
registry_lookup_unknown_model_returns_not_found_test() ->
    ?assertEqual(not_found, erllama_server_tool_format:lookup(<<"nope-no-manifest">>)).
