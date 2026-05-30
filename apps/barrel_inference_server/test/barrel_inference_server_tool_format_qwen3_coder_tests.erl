%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_qwen3_coder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_tool_format_qwen3_coder).

%% Build a native Qwen3-Coder call body.
call(Name, Params) ->
    Ps = [[<<"<parameter=">>, K, <<">\n">>, V, <<"\n</parameter>\n">>] || {K, V} <- Params],
    iolist_to_binary([
        <<"<tool_call>\n<function=">>, Name, <<">\n">>, Ps, <<"</function>\n</tool_call>">>
    ]).

%% =============================================================================
%% parse
%% =============================================================================

parse_single_param_test() ->
    Bin = call(<<"get_weather">>, [{<<"city">>, <<"Paris">>}]),
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?M:parse(Bin)
    ).

parse_multi_param_and_typed_test() ->
    Bin = call(<<"search">>, [
        {<<"ds">>, <<"lk-monitor-southeast-ph">>},
        {<<"limit">>, <<"50">>},
        {<<"verbose">>, <<"true">>}
    ]),
    ?assertEqual(
        {ok, #{
            name => <<"search">>,
            arguments => #{
                %% bare string stays binary; numbers/bools recovered as typed
                <<"ds">> => <<"lk-monitor-southeast-ph">>,
                <<"limit">> => 50,
                <<"verbose">> => true
            }
        }},
        ?M:parse(Bin)
    ).

parse_multiline_value_test() ->
    Bin = call(<<"run">>, [{<<"query">>, <<"line one\nline two">>}]),
    ?assertEqual(
        {ok, #{name => <<"run">>, arguments => #{<<"query">> => <<"line one\nline two">>}}},
        ?M:parse(Bin)
    ).

parse_no_params_test() ->
    Bin = iolist_to_binary([<<"<tool_call>\n<function=ping>\n</function>\n</tool_call>">>]),
    ?assertEqual({ok, #{name => <<"ping">>, arguments => #{}}}, ?M:parse(Bin)).

parse_mcp_prefixed_name_test() ->
    Bin = call(<<"mcp__grafana__grafana_list_labels">>, [{<<"ds">>, <<"lk-monitor-southeast-ph">>}]),
    ?assertMatch(
        {ok, #{name := <<"mcp__grafana__grafana_list_labels">>, arguments := #{<<"ds">> := _}}},
        ?M:parse(Bin)
    ).

parse_object_argument_test() ->
    Bin = call(<<"f">>, [{<<"opts">>, <<"{\"a\":1}">>}]),
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"opts">> => #{<<"a">> => 1}}}},
        ?M:parse(Bin)
    ).

parse_malformed_no_function_test() ->
    ?assertEqual({error, no_function}, ?M:parse(<<"<tool_call>\njust text\n</tool_call>">>)).

%% =============================================================================
%% canonicalise (round-trips through parse)
%% =============================================================================

canonicalise_round_trips_test() ->
    Call = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    ?assertEqual({ok, Call}, ?M:parse(?M:canonicalise(Call))).

canonicalise_typed_values_round_trip_test() ->
    Call = #{name => <<"search">>, arguments => #{<<"limit">> => 50, <<"verbose">> => true}},
    ?assertEqual({ok, Call}, ?M:parse(?M:canonicalise(Call))).

%% =============================================================================
%% family_name/0 + detect/1
%% =============================================================================

qwen3_coder_family_name_test() ->
    ?assertEqual(<<"qwen3-coder">>, ?M:family_name()).

qwen3_coder_detect_positive_test() ->
    Template =
        <<"<tool_call>\n<function=foo>\n<parameter=x>\n1\n</parameter>\n</function>\n</tool_call>">>,
    ?assertEqual(
        {detected, #{start => <<"<tool_call>">>, 'end' => <<"</tool_call>">>}},
        ?M:detect(Template)
    ).

qwen3_coder_detect_negative_test() ->
    %% Plain qwen-xml template (no `<function=') must NOT detect as
    %% qwen3-coder.
    Template = <<"<tool_call>{\"name\":\"f\",\"arguments\":{}}</tool_call>">>,
    ?assertEqual(not_detected, ?M:detect(Template)).
