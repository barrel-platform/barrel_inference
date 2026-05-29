%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_dsml_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DSML, barrel_inference_server_tool_format_dsml).

%% =============================================================================
%% Helpers - reuse the module's UTF-8 marker bytes so tests stay in sync
%% with the production constants if they're ever adjusted upstream.
%% =============================================================================

call_begin() -> <<"<｜tool▁call▁begin｜>"/utf8>>.
call_end() -> <<"<｜tool▁call▁end｜>"/utf8>>.
calls_begin() -> <<"<｜tool▁calls▁begin｜>"/utf8>>.
calls_end() -> <<"<｜tool▁calls▁end｜>"/utf8>>.
sep() -> <<"<｜tool▁sep｜>"/utf8>>.

canonical_call(Name, ArgsJson) ->
    iolist_to_binary([
        call_begin(),
        <<"function">>,
        sep(),
        Name,
        <<"\n```json\n">>,
        ArgsJson,
        <<"\n```">>,
        call_end()
    ]).

%% =============================================================================
%% parse: canonical and tolerant shapes
%% =============================================================================

dsml_parses_canonical_test() ->
    Bin = canonical_call(<<"get_weather">>, <<"{\"city\":\"Paris\"}">>),
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_with_outer_batch_wrapper_test() ->
    Inner = canonical_call(<<"f">>, <<"{}">>),
    Bin = iolist_to_binary([calls_begin(), Inner, calls_end()]),
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_without_function_type_prefix_test() ->
    %% Variant where the leading `function<sep>' is omitted.
    Bin = iolist_to_binary([
        call_begin(),
        <<"do_it\n```json\n{\"x\":1}\n```">>,
        call_end()
    ]),
    ?assertEqual(
        {ok, #{name => <<"do_it">>, arguments => #{<<"x">> => 1}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_without_json_fence_test() ->
    %% Some fine-tunes drop the ```json ... ``` fence.
    Bin = iolist_to_binary([
        call_begin(),
        <<"function">>,
        sep(),
        <<"do_it\n{\"x\":2}">>,
        call_end()
    ]),
    ?assertEqual(
        {ok, #{name => <<"do_it">>, arguments => #{<<"x">> => 2}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_with_leading_whitespace_test() ->
    Bin = iolist_to_binary([<<"\n  ">>, canonical_call(<<"f">>, <<"{}">>), <<"\n">>]),
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{}}},
        ?DSML:parse(Bin)
    ).

%% =============================================================================
%% parse: marker-stripped real-backend shape
%%
%% The NIF detokenizer runs with `special=false', which drops control-
%% token markers from the captured FullBin. For dsml that includes the
%% inner `<｜tool▁sep｜>' separator, so the body the parser sees is
%% typically `functionNAME\n```json\n{ARGS}\n```' (literal `function'
%% text fused to the name, no sep, the outer call-markers gone too).
%% =============================================================================

dsml_parses_stripped_markers_test() ->
    %% Canonical with all special tokens dropped: `function' prefix
    %% remains as literal text fused to the name.
    Bin = <<"functiondo_it\n```json\n{\"x\":1}\n```">>,
    ?assertEqual(
        {ok, #{name => <<"do_it">>, arguments => #{<<"x">> => 1}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_stripped_markers_without_function_prefix_test() ->
    %% Some configurations / fine-tunes omit the `function' type prefix
    %% in the canonical template; with markers stripped the body is then
    %% just `NAME\n```json\n{ARGS}\n```'.
    Bin = <<"do_it\n```json\n{}\n```">>,
    ?assertEqual(
        {ok, #{name => <<"do_it">>, arguments => #{}}},
        ?DSML:parse(Bin)
    ).

dsml_parses_stripped_markers_strips_function_prefix_always_test() ->
    %% Documented trade-off: in the marker-stripped path the literal
    %% `function' text is indistinguishable from the canonical type
    %% prefix and is always stripped. DeepSeek's canonical wire
    %% protocol reserves `function' as a type prefix, so user-defined
    %% tools should not name a function starting with `function' - if
    %% one does (e.g. `functionGetData'), the marker-stripped capture
    %% parses as `GetData' here.
    Bin = <<"functionGetData\n```json\n{}\n```">>,
    ?assertEqual(
        {ok, #{name => <<"GetData">>, arguments => #{}}},
        ?DSML:parse(Bin)
    ).

%% =============================================================================
%% parse: rejections
%% =============================================================================

dsml_rejects_invalid_json_test() ->
    Bin = iolist_to_binary([
        call_begin(),
        <<"function">>,
        sep(),
        <<"f\n```json\n{not_json\n```">>,
        call_end()
    ]),
    ?assertMatch({error, _}, ?DSML:parse(Bin)).

dsml_rejects_empty_name_test() ->
    Bin = iolist_to_binary([
        call_begin(),
        <<"function">>,
        sep(),
        <<"\n```json\n{}\n```">>,
        call_end()
    ]),
    ?assertMatch({error, _}, ?DSML:parse(Bin)).

dsml_rejects_no_arguments_section_test() ->
    Bin = iolist_to_binary([
        call_begin(),
        <<"function">>,
        sep(),
        <<"f">>,
        call_end()
    ]),
    ?assertMatch({error, _}, ?DSML:parse(Bin)).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

dsml_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?DSML:canonicalise(Json),
    ?assertEqual({ok, Json}, ?DSML:parse(Bin)).

dsml_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?DSML:canonicalise(Json),
    ?assertEqual({ok, Json}, ?DSML:parse(Bin)).

dsml_canonicalise_round_trip_nested_test() ->
    Json = #{
        name => <<"search">>,
        arguments => #{
            <<"q">> => <<"erlang">>,
            <<"filters">> => #{<<"lang">> => <<"en">>, <<"limit">> => 10}
        }
    },
    Bin = ?DSML:canonicalise(Json),
    ?assertEqual({ok, Json}, ?DSML:parse(Bin)).

%% =============================================================================
%% registry dispatch via the public API
%% =============================================================================

dsml_registry_dispatch_test() ->
    Spec = #{module => ?DSML},
    Bin = canonical_call(<<"a">>, <<"{}">>),
    ?assertEqual(
        {ok, #{name => <<"a">>, arguments => #{}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).
