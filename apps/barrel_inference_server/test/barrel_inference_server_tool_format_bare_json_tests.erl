%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_bare_json_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BARE, barrel_inference_server_tool_format_bare_json).

%% =============================================================================
%% parse
%% =============================================================================

bare_json_parses_canonical_test() ->
    Bin = <<"{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}">>,
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?BARE:parse(Bin)
    ).

bare_json_parses_with_parameters_key_test() ->
    Bin = <<"{\"name\":\"f\",\"parameters\":{\"x\":1}}">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?BARE:parse(Bin)
    ).

bare_json_parses_with_whitespace_test() ->
    Bin = <<"\n  {\"name\":\"f\",\"arguments\":{}}  \n">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?BARE:parse(Bin)
    ).

bare_json_defaults_missing_arguments_to_empty_map_test() ->
    Bin = <<"{\"name\":\"noop\"}">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?BARE:parse(Bin)
    ).

%% =============================================================================
%% parse: rejections
%% =============================================================================

bare_json_rejects_empty_input_test() ->
    ?assertEqual({error, empty}, ?BARE:parse(<<>>)).

bare_json_rejects_whitespace_only_test() ->
    ?assertEqual({error, empty}, ?BARE:parse(<<"   \n  ">>)).

bare_json_rejects_invalid_json_test() ->
    ?assertMatch({error, _}, ?BARE:parse(<<"{not_json}">>)).

bare_json_rejects_payload_without_name_test() ->
    ?assertMatch({error, _}, ?BARE:parse(<<"{\"arguments\":{}}">>)).

bare_json_rejects_non_object_payload_test() ->
    ?assertMatch({error, _}, ?BARE:parse(<<"[{\"name\":\"f\"}]">>)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

bare_json_canonicalise_emits_no_wrapper_test() ->
    Bin = ?BARE:canonicalise(#{name => <<"f">>, arguments => #{}}),
    %% First non-whitespace char must be `{', not a marker.
    ?assertEqual(<<"{">>, binary:part(Bin, 0, 1)).

bare_json_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?BARE:canonicalise(Json),
    ?assertEqual({ok, Json}, ?BARE:parse(Bin)).

bare_json_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?BARE:canonicalise(Json),
    ?assertEqual({ok, Json}, ?BARE:parse(Bin)).

bare_json_canonicalise_round_trip_nested_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?BARE:canonicalise(Json),
    ?assertEqual({ok, Json}, ?BARE:parse(Bin)).

%% =============================================================================
%% registry dispatch via the public API
%% =============================================================================

bare_json_registry_dispatch_test() ->
    Spec = #{module => ?BARE},
    Bin = <<"{\"name\":\"a\",\"arguments\":{}}">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).

%% =============================================================================
%% family_name/0 + detect/1
%% =============================================================================

bare_json_family_name_test() ->
    ?assertEqual(<<"bare-json">>, ?BARE:family_name()).

%% Runtime-configured catch-all: `detect/1' returns `not_detected'
%% for every template. No positive detection test by design.
bare_json_detect_returns_not_detected_test() ->
    ?assertEqual(not_detected, ?BARE:detect(<<"{\"any\":\"template\"}">>)),
    ?assertEqual(not_detected, ?BARE:detect(<<"<tool_call>foo</tool_call>">>)),
    ?assertEqual(not_detected, ?BARE:detect(<<"">>)).
