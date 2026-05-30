%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_glm45_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_tool_format_glm45).

%% =============================================================================
%% parse/1: canonical and tolerant shapes
%% =============================================================================

glm45_parses_canonical_with_markers_test() ->
    Bin =
        <<
            "<tool_call>get_weather\n"
            "<arg_key>city</arg_key>\n"
            "<arg_value>Paris</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

%% The engine strips markers before handing the FullBin to parse/1; we
%% accept the marker-less body too (qwen3-coder lineage tolerance).
glm45_parses_body_without_markers_test() ->
    Bin =
        <<
            "get_weather\n"
            "<arg_key>city</arg_key>\n"
            "<arg_value>Paris</arg_value>\n"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

glm45_parses_with_surrounding_whitespace_test() ->
    Bin =
        <<
            "\n  <tool_call>f\n"
            "<arg_key>k</arg_key>\n"
            "<arg_value>v</arg_value>\n"
            "</tool_call>  \n"
        >>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"k">> => <<"v">>}}},
        ?M:parse(Bin)
    ).

glm45_parses_multi_arg_test() ->
    Bin =
        <<
            "<tool_call>get_weather\n"
            "<arg_key>city</arg_key>\n"
            "<arg_value>Paris</arg_value>\n"
            "<arg_key>units</arg_key>\n"
            "<arg_value>metric</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>, <<"units">> => <<"metric">>}
        }},
        ?M:parse(Bin)
    ).

glm45_parses_no_args_test() ->
    Bin = <<"<tool_call>ping\n</tool_call>">>,
    ?assertEqual(
        {ok, #{name => <<"ping">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

%% Key correctness assertion for the typed-value coercion: the GLM
%% template renders non-string values via `tojson(ensure_ascii=False)',
%% so an integer or array round-trips through json:decode/1.
glm45_decodes_typed_values_test() ->
    Bin =
        <<
            "<tool_call>f\n"
            "<arg_key>n</arg_key>\n"
            "<arg_value>42</arg_value>\n"
            "<arg_key>ok</arg_key>\n"
            "<arg_value>true</arg_value>\n"
            "<arg_key>items</arg_key>\n"
            "<arg_value>[1, 2, 3]</arg_value>\n"
            "<arg_key>opts</arg_key>\n"
            "<arg_value>{\"strict\": true}</arg_value>\n"
            "<arg_key>name</arg_key>\n"
            "<arg_value>\"Paris\"</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{
                <<"n">> => 42,
                <<"ok">> => true,
                <<"items">> => [1, 2, 3],
                <<"opts">> => #{<<"strict">> => true},
                <<"name">> => <<"Paris">>
            }
        }},
        ?M:parse(Bin)
    ).

%% Bare strings render unquoted and are not valid JSON, so they stay
%% as raw binaries.
glm45_keeps_bare_strings_as_binary_test() ->
    Bin =
        <<
            "<tool_call>f\n"
            "<arg_key>id</arg_key>\n"
            "<arg_value>lk-monitor-southeast-ph</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{<<"id">> => <<"lk-monitor-southeast-ph">>}
        }},
        ?M:parse(Bin)
    ).

%% GLM legitimately emits newline-containing arg values; the regex
%% must run with `dotall' so `.' matches `\n'.
glm45_parses_multiline_arg_value_test() ->
    Bin =
        <<
            "<tool_call>f\n"
            "<arg_key>body</arg_key>\n"
            "<arg_value>line1\nline2\nline3</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{<<"body">> => <<"line1\nline2\nline3">>}
        }},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% rejections
%% =============================================================================

glm45_rejects_empty_body_test() ->
    ?assertEqual({error, no_name}, ?M:parse(<<"">>)).

glm45_rejects_missing_name_test() ->
    Bin = <<"<tool_call>\n<arg_key>k</arg_key>\n<arg_value>v</arg_value>\n</tool_call>">>,
    ?assertEqual({error, no_name}, ?M:parse(Bin)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

glm45_canonicalise_round_trip_single_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

glm45_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"ping">>, arguments => #{}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

glm45_canonicalise_round_trip_typed_args_test() ->
    Json = #{
        name => <<"process">>,
        arguments => #{
            <<"items">> => [1, 2, 3],
            <<"opts">> => #{<<"strict">> => true}
        }
    },
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

glm45_canonicalise_emits_markers_test() ->
    Bin = ?M:canonicalise(#{name => <<"f">>, arguments => #{}}),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"<tool_call>">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"</tool_call>">>)).

%% =============================================================================
%% registry dispatch
%% =============================================================================

glm45_registry_dispatch_test() ->
    Spec = #{module => ?M},
    Bin =
        <<
            "<tool_call>a\n"
            "<arg_key>k</arg_key>\n"
            "<arg_value>v</arg_value>\n"
            "</tool_call>"
        >>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{<<"k">> => <<"v">>}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).

%% =============================================================================
%% family_name/0 + detect/1
%% =============================================================================

glm45_family_name_test() ->
    ?assertEqual(<<"glm45">>, ?M:family_name()).

glm45_detect_positive_test() ->
    Template =
        <<"...<tool_call>f\n<arg_key>k</arg_key>\n<arg_value>v</arg_value>\n</tool_call>...">>,
    ?assertEqual(
        {detected, #{start => <<"<tool_call>">>, 'end' => <<"</tool_call>">>}},
        ?M:detect(Template)
    ).

glm45_detect_negative_test() ->
    %% A qwen3-coder template carries `<tool_call>' AND `<function='
    %% but NOT `<arg_key>'; glm45 must NOT detect it.
    Template = <<"<tool_call>\n<function=foo>\n</function>\n</tool_call>">>,
    ?assertEqual(not_detected, ?M:detect(Template)).
