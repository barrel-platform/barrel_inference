%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_mistral_args_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_tool_format_mistral_args).

%% =============================================================================
%% parse: canonical wire form (markers present)
%% =============================================================================

mistral_args_parses_canonical_test() ->
    Bin = <<"[TOOL_CALLS]get_weather[ARGS]{\"city\":\"Paris\"}">>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

mistral_args_parses_canonical_with_eos_test() ->
    Bin = <<"[TOOL_CALLS]get_weather[ARGS]{\"city\":\"Paris\"}</s>">>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

mistral_args_parses_with_surrounding_whitespace_test() ->
    Bin = <<"\n  [TOOL_CALLS]noop[ARGS]{}  \n">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

mistral_args_parses_with_whitespace_around_args_test() ->
    Bin = <<"[TOOL_CALLS]get_weather[ARGS]  {\"city\":\"Paris\"}  ">>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% parse: control-token-stripped wire form (the real backend shape)
%%
%% The detokenize NIF calls `llama_token_to_piece(..., special=false)`
%% which renders control tokens like `[TOOL_CALLS]` and `[ARGS]` as
%% empty pieces. So the FullBin captured for the engine's tool-call
%% span is typically `name{json}` with no marker bytes.
%% =============================================================================

mistral_args_parses_stripped_markers_test() ->
    Bin = <<"get_weather{\"city\":\"Paris\"}">>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

mistral_args_parses_stripped_markers_with_eos_test() ->
    Bin = <<"get_weather{\"city\":\"Paris\"}</s>">>,
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(Bin)
    ).

mistral_args_parses_stripped_markers_with_whitespace_test() ->
    Bin = <<"  noop  {}  \n">>,
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% parse: rejections
%% =============================================================================

mistral_args_rejects_no_name_test() ->
    ?assertEqual({error, no_name}, ?M:parse(<<"[TOOL_CALLS][ARGS]{}">>)).

mistral_args_rejects_no_name_stripped_test() ->
    ?assertEqual({error, no_name}, ?M:parse(<<"{}">>)).

mistral_args_rejects_invalid_json_test() ->
    Bin = <<"[TOOL_CALLS]f[ARGS]{garbage">>,
    ?assertEqual({error, invalid_json}, ?M:parse(Bin)).

mistral_args_rejects_non_object_args_test() ->
    Bin = <<"[TOOL_CALLS]f[ARGS][1,2,3]">>,
    ?assertEqual({error, args_not_object}, ?M:parse(Bin)).

%% Truncated capture: the model emitted the name but no JSON region.
%% Reject so the caller does NOT receive a fake `f({})` tool use.
mistral_args_rejects_empty_args_with_marker_test() ->
    ?assertEqual({error, empty_args}, ?M:parse(<<"[TOOL_CALLS]f[ARGS]">>)).

mistral_args_rejects_empty_args_stripped_test() ->
    ?assertEqual({error, empty_args}, ?M:parse(<<"f">>)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

mistral_args_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

mistral_args_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

mistral_args_canonicalise_round_trip_nested_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

mistral_args_canonicalise_emits_markers_test() ->
    Bin = ?M:canonicalise(#{name => <<"f">>, arguments => #{}}),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"[TOOL_CALLS]">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"[ARGS]">>)).

%% =============================================================================
%% registry dispatch via the public API
%% =============================================================================

mistral_args_registry_dispatch_test() ->
    Spec = #{module => ?M},
    Bin = <<"[TOOL_CALLS]a[ARGS]{}">>,
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).

%% =============================================================================
%% family_name/0 + detect/1 + payload_markers/0
%% =============================================================================

mistral_args_family_name_test() ->
    ?assertEqual(<<"mistral-args">>, ?M:family_name()).

mistral_args_payload_markers_test() ->
    ?assertEqual(#{<<"payload_start">> => <<"[ARGS]">>}, ?M:payload_markers()).

mistral_args_detect_positive_test() ->
    Template = <<"... [TOOL_CALLS]foo[ARGS]{\"x\":1} ...">>,
    ?assertEqual(
        {detected, #{start => <<"[TOOL_CALLS]">>, 'end' => <<"</s>">>}},
        ?M:detect(Template)
    ).

mistral_args_detect_negative_without_args_marker_test() ->
    %% Classic Mistral template - no `[ARGS]' marker.
    Template = <<"... [TOOL_CALLS][{\"name\":\"f\",\"arguments\":{}}] ...">>,
    ?assertEqual(not_detected, ?M:detect(Template)).

mistral_args_detect_negative_args_before_tool_calls_test() ->
    %% Instructions mention `[ARGS]' BEFORE `[TOOL_CALLS]'. The
    %% order-aware predicate must not misclassify as mistral-args.
    Template = <<"Instructions: use [ARGS] after the name. [TOOL_CALLS][{...}]">>,
    ?assertEqual(not_detected, ?M:detect(Template)).
