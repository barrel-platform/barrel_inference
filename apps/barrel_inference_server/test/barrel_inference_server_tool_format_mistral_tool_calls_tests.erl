%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_mistral_tool_calls_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MISTRAL, barrel_inference_server_tool_format_mistral_tool_calls).

%% =============================================================================
%% parse
%% =============================================================================

mistral_parses_canonical_test() ->
    Bin = <<"[TOOL_CALLS][{\"name\":\"f\",\"arguments\":{\"x\":1}}]</s>">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?MISTRAL:parse(Bin)
    ).

mistral_parses_without_eos_test() ->
    Bin = <<"[TOOL_CALLS][{\"name\":\"f\",\"arguments\":{}}]">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?MISTRAL:parse(Bin)
    ).

mistral_parses_with_surrounding_whitespace_test() ->
    Bin = <<"\n  [TOOL_CALLS][{\"name\":\"f\",\"arguments\":{}}]</s>  \n">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?MISTRAL:parse(Bin)
    ).

mistral_returns_first_call_of_multi_call_array_test() ->
    Bin =
        <<"[TOOL_CALLS][{\"name\":\"a\",\"arguments\":{}},{\"name\":\"b\",\"arguments\":{\"k\":2}}]</s>">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        ?MISTRAL:parse(Bin)
    ).

mistral_accepts_parameters_key_test() ->
    Bin = <<"[TOOL_CALLS][{\"name\":\"f\",\"parameters\":{\"x\":1}}]</s>">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?MISTRAL:parse(Bin)
    ).

mistral_defaults_missing_arguments_to_empty_map_test() ->
    Bin = <<"[TOOL_CALLS][{\"name\":\"noop\"}]</s>">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?MISTRAL:parse(Bin)
    ).

%% =============================================================================
%% parse: rejections
%% =============================================================================

mistral_rejects_missing_marker_test() ->
    ?assertEqual({error, no_markers}, ?MISTRAL:parse(<<"[{\"name\":\"f\"}]">>)).

mistral_rejects_invalid_json_test() ->
    ?assertMatch({error, _}, ?MISTRAL:parse(<<"[TOOL_CALLS][garbage</s>">>)).

mistral_rejects_empty_array_test() ->
    ?assertEqual({error, empty_array}, ?MISTRAL:parse(<<"[TOOL_CALLS][]</s>">>)).

mistral_rejects_non_array_payload_test() ->
    Bin = <<"[TOOL_CALLS]{\"name\":\"f\",\"arguments\":{}}</s>">>,
    ?assertEqual({error, not_an_array}, ?MISTRAL:parse(Bin)).

mistral_rejects_call_without_name_test() ->
    Bin = <<"[TOOL_CALLS][{\"arguments\":{}}]</s>">>,
    ?assertMatch({error, _}, ?MISTRAL:parse(Bin)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

mistral_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?MISTRAL:canonicalise(Json),
    ?assertEqual({ok, Json}, ?MISTRAL:parse(Bin)).

mistral_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?MISTRAL:canonicalise(Json),
    ?assertEqual({ok, Json}, ?MISTRAL:parse(Bin)).

mistral_canonicalise_round_trip_nested_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?MISTRAL:canonicalise(Json),
    ?assertEqual({ok, Json}, ?MISTRAL:parse(Bin)).

mistral_canonicalise_wraps_call_in_array_test() ->
    Bin = ?MISTRAL:canonicalise(#{name => <<"f">>, arguments => #{}}),
    %% The canonical form wraps the call in a JSON array, matching
    %% the Mistral v3 chat template shape.
    ?assertMatch({nomatch, _}, {binary:match(Bin, <<"[TOOL_CALLS]{">>), Bin}).

%% =============================================================================
%% registry dispatch via the public API
%% =============================================================================

mistral_registry_dispatch_test() ->
    Spec = #{module => ?MISTRAL},
    Bin = <<"[TOOL_CALLS][{\"name\":\"a\",\"arguments\":{}}]</s>">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).
