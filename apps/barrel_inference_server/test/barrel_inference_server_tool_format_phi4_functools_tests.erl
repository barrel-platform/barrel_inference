%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_phi4_functools_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_tool_format_phi4_functools).

%% =============================================================================
%% parse/1 + parse_all/1: canonical and tolerant shapes
%% =============================================================================

phi4_parses_canonical_test() ->
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(<<"functools[{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}]">>)
    ).

phi4_parses_with_surrounding_whitespace_test() ->
    Bin = <<"\n  functools[{\"name\":\"f\",\"arguments\":{}}]  \n">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

phi4_parses_with_surrounding_prose_test() ->
    %% Phi-4 occasionally emits prose before the call; the extractor
    %% finds `functools[' anywhere in the buffer.
    Bin =
        <<"Sure, here is the call:\nfunctools[{\"name\":\"f\",\"arguments\":{}}]\nLet me know if you need more.">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

phi4_parses_multi_call_test() ->
    Bin =
        <<
            "functools[{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}},"
            "{\"name\":\"get_time\",\"arguments\":{\"tz\":\"UTC\"}}]"
        >>,
    ?assertEqual(
        {ok, [
            #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
            #{name => <<"get_time">>, arguments => #{<<"tz">> => <<"UTC">>}}
        ]},
        ?M:parse_all(Bin)
    ).

%% Key correctness assertion: depth-tracked extractor must NOT close on
%% a `]' inside a nested JSON array argument value.
phi4_parses_nested_array_arg_test() ->
    Bin =
        <<"functools[{\"name\":\"process\",\"arguments\":{\"items\":[1,2,3]}}]">>,
    ?assertEqual(
        {ok, #{
            name => <<"process">>,
            arguments => #{<<"items">> => [1, 2, 3]}
        }},
        ?M:parse(Bin)
    ).

%% Depth track must also ignore `]' inside JSON string values.
phi4_parses_close_bracket_in_string_arg_test() ->
    Bin =
        <<"functools[{\"name\":\"echo\",\"arguments\":{\"q\":\"a]b]c\"}}]">>,
    ?assertEqual(
        {ok, #{
            name => <<"echo">>,
            arguments => #{<<"q">> => <<"a]b]c">>}
        }},
        ?M:parse(Bin)
    ).

%% Escaped quote inside a string must not toggle the in-string state.
phi4_parses_escaped_quote_in_string_arg_test() ->
    Bin = <<"functools[{\"name\":\"say\",\"arguments\":{\"text\":\"\\\"hi\\\"\"}}]">>,
    ?assertEqual(
        {ok, #{
            name => <<"say">>,
            arguments => #{<<"text">> => <<"\"hi\"">>}
        }},
        ?M:parse(Bin)
    ).

phi4_parses_parameters_key_alias_test() ->
    %% Some fine-tunes emit `parameters' instead of `arguments'.
    Bin = <<"functools[{\"name\":\"f\",\"parameters\":{\"x\":1}}]">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?M:parse(Bin)
    ).

phi4_parses_missing_arguments_defaults_to_empty_map_test() ->
    Bin = <<"functools[{\"name\":\"noop\"}]">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% rejections
%% =============================================================================

phi4_rejects_missing_prefix_test() ->
    ?assertEqual({error, no_markers}, ?M:parse(<<"[{\"name\":\"f\"}]">>)).

phi4_rejects_unterminated_array_test() ->
    ?assertMatch(
        {error, _},
        ?M:parse(<<"functools[{\"name\":\"f\",\"arguments\":{}">>)
    ).

phi4_rejects_empty_array_test() ->
    ?assertEqual({error, empty_array}, ?M:parse(<<"functools[]">>)).

phi4_rejects_non_array_payload_test() ->
    Bin = <<"functools[\"not_an_object\"]">>,
    ?assertEqual({error, malformed_call}, ?M:parse(Bin)).

phi4_rejects_invalid_json_test() ->
    ?assertEqual(
        {error, invalid_json},
        ?M:parse(<<"functools[garbage]">>)
    ).

phi4_rejects_call_without_name_test() ->
    Bin = <<"functools[{\"arguments\":{}}]">>,
    ?assertMatch({error, _}, ?M:parse(Bin)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

phi4_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

phi4_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

phi4_canonicalise_round_trip_nested_args_test() ->
    Json = #{
        name => <<"process">>,
        arguments => #{
            <<"items">> => [1, 2, 3],
            <<"opts">> => #{<<"strict">> => true}
        }
    },
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

phi4_canonicalise_emits_functools_marker_test() ->
    Bin = ?M:canonicalise(#{name => <<"f">>, arguments => #{}}),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"functools[">>)).

%% =============================================================================
%% post_parse_mode + registry dispatch
%% =============================================================================

phi4_post_parse_mode_is_functools_test() ->
    ?assertEqual(functools, ?M:post_parse_mode()).

phi4_registry_dispatch_test() ->
    Spec = #{module => ?M},
    Bin = <<"functools[{\"name\":\"a\",\"arguments\":{}}]">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).

phi4_shared_post_parse_mode_helper_test() ->
    Spec = #{module => ?M},
    ?assertEqual(
        functools,
        barrel_inference_server_tool_format:post_parse_mode(Spec)
    ).
