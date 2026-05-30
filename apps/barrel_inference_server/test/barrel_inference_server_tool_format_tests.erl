%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QWEN, barrel_inference_server_tool_format_qwen_xml).
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
        barrel_inference_server_tool_format:parse(?SPEC, Bin)
    ).

registry_canonicalise_dispatches_to_module_test() ->
    Json = #{name => <<"a">>, arguments => #{}},
    Bin = barrel_inference_server_tool_format:canonicalise(?SPEC, Json),
    ?assertEqual({ok, Json}, ?QWEN:parse(Bin)).

%% Lookup against a model id that has no manifest entry returns
%% not_found. Manifest-driven lookup is covered end-to-end in PR 5.
registry_lookup_unknown_model_returns_not_found_test() ->
    ?assertEqual(not_found, barrel_inference_server_tool_format:lookup(<<"nope-no-manifest">>)).

%% =============================================================================
%% qwen-xml family_name/0 + detect/1
%% =============================================================================

qwen_xml_family_name_test() ->
    ?assertEqual(<<"qwen-xml">>, ?QWEN:family_name()).

qwen_xml_detect_positive_test() ->
    %% Template carrying `<tool_call>' but neither qwen3-coder's
    %% `<function=' nor glm45's `<arg_key>' - qwen-xml is the
    %% fall-through for `<tool_call>'.
    Template = <<"...<tool_call>{ name, args }</tool_call>...">>,
    ?assertEqual(
        {detected, #{start => <<"<tool_call>">>, 'end' => <<"</tool_call>">>}},
        ?QWEN:detect(Template)
    ).

qwen_xml_detect_negative_test() ->
    ?assertEqual(not_detected, ?QWEN:detect(<<"{% for x in y %}{{ x }}{% endfor %}">>)).

%% =============================================================================
%% include-file family list invariants (two-place-add guarantee)
%% =============================================================================

%% `families/0' returns the include-file list verbatim. Order
%% matters: the dispatch walks the list top to bottom and the
%% first `{detected, _}' wins.
families_list_is_stable_test() ->
    Families = barrel_inference_server_tool_format:families(),
    ?assertEqual(10, length(Families)),
    ?assertEqual(barrel_inference_server_tool_format_qwen3_coder, hd(Families)),
    ?assertEqual(barrel_inference_server_tool_format_bare_json, lists:last(Families)).

%% `formats/0' returns one registry entry per family in the list,
%% keyed by each family's own `family_name/0'. Proves the registry
%% map is derived from the include macro (not a hand-rolled
%% duplicate).
formats_map_built_from_families_test() ->
    Formats = barrel_inference_server_tool_format:formats(),
    Families = barrel_inference_server_tool_format:families(),
    ?assertEqual(length(Families), map_size(Formats)),
    lists:foreach(
        fun(Mod) ->
            Name = Mod:family_name(),
            ?assert(maps:is_key(Name, Formats)),
            ?assertEqual(#{module => Mod}, maps:get(Name, Formats))
        end,
        Families
    ).

%% qwen3-coder and qwen-xml both detect `<tool_call>' templates,
%% but qwen3-coder requires the extra `<function=' substring. A
%% template with BOTH `<tool_call>' AND `<function=' MUST detect
%% as qwen3-coder (list order: qwen3-coder precedes qwen-xml).
detect_walks_families_in_include_order_test() ->
    Template = <<"<tool_call>\n<function=foo>\nx\n</function>\n</tool_call>">>,
    ?assertEqual(
        {ok, <<"qwen3-coder">>, #{
            start => <<"<tool_call>">>, 'end' => <<"</tool_call>">>
        }},
        barrel_inference_server_tool_format:detect(Template)
    ).

%% Generic template that matches no family.
detect_returns_not_detected_for_unknown_template_test() ->
    ?assertEqual(
        not_detected,
        barrel_inference_server_tool_format:detect(<<"{% for x in y %}{{ x }}{% endfor %}">>)
    ).

%% `payload_markers/1' looks up by family name and returns the
%% family's extras. mistral-args is the only family that ships any.
payload_markers_for_mistral_args_returns_payload_start_test() ->
    ?assertEqual(
        #{<<"payload_start">> => <<"[ARGS]">>},
        barrel_inference_server_tool_format:payload_markers(<<"mistral-args">>)
    ).

payload_markers_for_qwen_xml_returns_undefined_test() ->
    ?assertEqual(
        undefined,
        barrel_inference_server_tool_format:payload_markers(<<"qwen-xml">>)
    ).

payload_markers_for_unknown_family_returns_undefined_test() ->
    ?assertEqual(
        undefined,
        barrel_inference_server_tool_format:payload_markers(<<"no-such-family">>)
    ).
