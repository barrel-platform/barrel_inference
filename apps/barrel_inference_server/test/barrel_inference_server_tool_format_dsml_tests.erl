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
