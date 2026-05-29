%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_llama_python_tag_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LLAMA, barrel_inference_server_tool_format_llama_python_tag).

%% =============================================================================
%% parse
%% =============================================================================

llama_parses_canonical_test() ->
    Bin =
        <<"<|python_tag|>{\"name\":\"get_weather\",\"parameters\":{\"city\":\"Paris\"}}<|eom_id|>">>,
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?LLAMA:parse(Bin)
    ).

llama_parses_with_arguments_key_test() ->
    %% Some fine-tunes emit `arguments` instead of `parameters`.
    Bin = <<"<|python_tag|>{\"name\":\"f\",\"arguments\":{\"x\":1}}<|eom_id|>">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?LLAMA:parse(Bin)
    ).

llama_parses_without_eom_id_terminator_test() ->
    Bin = <<"<|python_tag|>{\"name\":\"f\",\"parameters\":{\"x\":1}}">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?LLAMA:parse(Bin)
    ).

llama_parses_with_surrounding_whitespace_test() ->
    Bin = <<"\n  <|python_tag|>{\"name\":\"f\",\"parameters\":{}}<|eom_id|>  \n">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?LLAMA:parse(Bin)
    ).

llama_defaults_missing_parameters_to_empty_map_test() ->
    Bin = <<"<|python_tag|>{\"name\":\"noop\"}<|eom_id|>">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?LLAMA:parse(Bin)
    ).

%% =============================================================================
%% parse: marker-stripped real-backend shape
%%
%% The NIF detokenizer runs with `special=false', which drops control-
%% token markers (`<|python_tag|>', `<|eom_id|>') from the captured
%% FullBin, so the body the parser actually sees on a real backend is a
%% bare JSON object. The parser must accept both shapes.
%% =============================================================================

llama_parses_stripped_markers_test() ->
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?LLAMA:parse(<<"{\"name\":\"f\",\"parameters\":{}}">>)
    ).

llama_parses_stripped_markers_with_arguments_key_test() ->
    %% Some Llama 3.x fine-tunes emit `arguments' instead of `parameters'.
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        ?LLAMA:parse(<<"{\"name\":\"f\",\"arguments\":{\"x\":1}}">>)
    ).

llama_parses_stripped_markers_with_eom_id_only_test() ->
    %% Edge case: the start marker drops but the end marker is preserved
    %% by some loader configs (or arrives as plain text). Both tolerances
    %% must compose.
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?LLAMA:parse(<<"{\"name\":\"f\",\"parameters\":{}}<|eom_id|>">>)
    ).

llama_parses_stripped_markers_with_surrounding_whitespace_test() ->
    Bin = <<"\n  {\"name\":\"f\",\"parameters\":{}}  \n">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?LLAMA:parse(Bin)
    ).

%% =============================================================================
%% parse: rejections
%% =============================================================================

llama_rejects_invalid_json_test() ->
    Bin = <<"<|python_tag|>{garbage<|eom_id|>">>,
    ?assertMatch({error, _}, ?LLAMA:parse(Bin)).

llama_rejects_payload_without_name_test() ->
    Bin = <<"<|python_tag|>{\"parameters\":{}}<|eom_id|>">>,
    ?assertMatch({error, _}, ?LLAMA:parse(Bin)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

llama_canonicalise_emits_parameters_key_test() ->
    Json = #{name => <<"f">>, arguments => #{<<"x">> => 1}},
    Bin = ?LLAMA:canonicalise(Json),
    %% The canonical form uses `parameters' (the form the model
    %% itself emits and prompt templates expect).
    ?assertMatch(
        {true, _},
        {binary:match(Bin, <<"\"parameters\"">>) =/= nomatch, Bin}
    ).

llama_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?LLAMA:canonicalise(Json),
    ?assertEqual({ok, Json}, ?LLAMA:parse(Bin)).

llama_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?LLAMA:canonicalise(Json),
    ?assertEqual({ok, Json}, ?LLAMA:parse(Bin)).

llama_canonicalise_round_trip_nested_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?LLAMA:canonicalise(Json),
    ?assertEqual({ok, Json}, ?LLAMA:parse(Bin)).

%% =============================================================================
%% registry dispatch via the public API
%% =============================================================================

llama_registry_dispatch_test() ->
    Spec = #{module => ?LLAMA},
    Bin = <<"<|python_tag|>{\"name\":\"a\",\"parameters\":{}}<|eom_id|>">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).
