%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_format_llama_pythonic_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_tool_format_llama_pythonic).

%% =============================================================================
%% parse/1: single-call entry, accepts both wrapped and unwrapped shapes
%% =============================================================================

llama_pythonic_parses_canonical_wrapped_test() ->
    ?assertEqual(
        {ok, #{
            name => <<"get_weather">>,
            arguments => #{<<"city">> => <<"Paris">>}
        }},
        ?M:parse(<<"[get_weather(city='Paris')]">>)
    ).

llama_pythonic_parses_unwrapped_single_call_test() ->
    %% A single call without the outer `[' / `]' is still accepted (the
    %% post-parse path strips the wrapper before dispatching).
    ?assertEqual(
        {ok, #{name => <<"noop">>, arguments => #{}}},
        ?M:parse(<<"noop()">>)
    ).

llama_pythonic_parses_with_eot_trailer_test() ->
    Bin = <<"[get_weather(city='Paris')]<|eot_id|>">>,
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?M:parse(Bin)
    ).

llama_pythonic_parses_with_surrounding_whitespace_test() ->
    Bin = <<"\n  [ get_weather ( city = 'Paris' ) ]  \n">>,
    ?assertEqual(
        {ok, #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}}},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% parse/1: argument-value tolerance (Python and JSON literals)
%% =============================================================================

llama_pythonic_parses_single_quoted_strings_test() ->
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{<<"q">> => <<"erlang/OTP">>}
        }},
        ?M:parse(<<"[f(q='erlang/OTP')]">>)
    ).

llama_pythonic_parses_double_quoted_strings_test() ->
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{<<"q">> => <<"erlang/OTP">>}
        }},
        ?M:parse(<<"[f(q=\"erlang/OTP\")]">>)
    ).

llama_pythonic_parses_python_boolean_and_none_test() ->
    Bin = <<"[f(a=True, b=False, c=None)]">>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{
                <<"a">> => true,
                <<"b">> => false,
                <<"c">> => null
            }
        }},
        ?M:parse(Bin)
    ).

llama_pythonic_parses_json_boolean_and_null_test() ->
    %% Tolerance: vLLM / llama.cpp parsers accept both Python and JSON
    %% literals; we mirror that.
    Bin = <<"[f(a=true, b=false, c=null)]">>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{
                <<"a">> => true,
                <<"b">> => false,
                <<"c">> => null
            }
        }},
        ?M:parse(Bin)
    ).

llama_pythonic_parses_numbers_test() ->
    Bin = <<"[f(i=42, neg=-7, flt=3.14, exp=1.5e3)]">>,
    {ok, #{arguments := Args}} = ?M:parse(Bin),
    ?assertEqual(42, maps:get(<<"i">>, Args)),
    ?assertEqual(-7, maps:get(<<"neg">>, Args)),
    ?assertEqual(3.14, maps:get(<<"flt">>, Args)),
    ?assertEqual(1500.0, maps:get(<<"exp">>, Args)).

llama_pythonic_parses_nested_list_arg_test() ->
    Bin = <<"[f(items=['a', 'b', 'c'])]">>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{<<"items">> => [<<"a">>, <<"b">>, <<"c">>]}
        }},
        ?M:parse(Bin)
    ).

llama_pythonic_parses_nested_dict_arg_test() ->
    Bin = <<"[f(filters={'lang': 'en', 'limit': 10})]">>,
    ?assertEqual(
        {ok, #{
            name => <<"f">>,
            arguments => #{
                <<"filters">> => #{
                    <<"lang">> => <<"en">>,
                    <<"limit">> => 10
                }
            }
        }},
        ?M:parse(Bin)
    ).

llama_pythonic_parses_backslash_escape_in_string_test() ->
    %% A backslash escapes the next char verbatim; `'it\'s'' -> `it's'.
    Bin = <<"[say(text='it\\'s fine')]">>,
    ?assertEqual(
        {ok, #{name => <<"say">>, arguments => #{<<"text">> => <<"it's fine">>}}},
        ?M:parse(Bin)
    ).

%% =============================================================================
%% parse_all/1: multi-call extraction
%% =============================================================================

llama_pythonic_parse_all_single_call_test() ->
    ?assertEqual(
        {ok, [#{name => <<"f">>, arguments => #{}}]},
        ?M:parse_all(<<"[f()]">>)
    ).

llama_pythonic_parse_all_multi_call_test() ->
    Bin = <<"[get_weather(city='Paris'), get_time(tz='UTC')]">>,
    ?assertEqual(
        {ok, [
            #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
            #{name => <<"get_time">>, arguments => #{<<"tz">> => <<"UTC">>}}
        ]},
        ?M:parse_all(Bin)
    ).

llama_pythonic_parse_all_with_eot_test() ->
    Bin = <<"[f(a=1), g(b=2)]<|eot_id|>">>,
    ?assertEqual(
        {ok, [
            #{name => <<"f">>, arguments => #{<<"a">> => 1}},
            #{name => <<"g">>, arguments => #{<<"b">> => 2}}
        ]},
        ?M:parse_all(Bin)
    ).

llama_pythonic_parse_all_unwrapped_test() ->
    %% A single call without the outer wrapper is still returned as a
    %% one-element list.
    ?assertEqual(
        {ok, [#{name => <<"f">>, arguments => #{<<"x">> => 1}}]},
        ?M:parse_all(<<"f(x=1)">>)
    ).

%% =============================================================================
%% rejections
%% =============================================================================

llama_pythonic_rejects_empty_input_test() ->
    ?assertMatch({error, _}, ?M:parse(<<>>)),
    ?assertMatch({error, _}, ?M:parse_all(<<>>)).

llama_pythonic_rejects_unterminated_string_test() ->
    ?assertMatch(
        {error, unterminated_string},
        ?M:parse(<<"[f(q='unterminated)]">>)
    ).

llama_pythonic_rejects_missing_open_paren_test() ->
    ?assertMatch(
        {error, expected_open_paren},
        ?M:parse(<<"[f arg]">>)
    ).

llama_pythonic_rejects_missing_equals_test() ->
    ?assertMatch(
        {error, expected_equals},
        ?M:parse(<<"[f(x)]">>)
    ).

llama_pythonic_rejects_malformed_number_test() ->
    ?assertMatch(
        {error, malformed_number},
        ?M:parse(<<"[f(n=1.2.3)]">>)
    ).

%% =============================================================================
%% canonicalise + round-trip
%% =============================================================================

llama_pythonic_canonicalise_round_trip_test() ->
    Json = #{name => <<"get_weather">>, arguments => #{<<"city">> => <<"Paris">>}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

llama_pythonic_canonicalise_round_trip_empty_args_test() ->
    Json = #{name => <<"noop">>, arguments => #{}},
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

llama_pythonic_canonicalise_round_trip_mixed_literals_test() ->
    Json = #{
        name => <<"call">>,
        arguments => #{
            <<"flag">> => true,
            <<"missing">> => null,
            <<"count">> => 3,
            <<"items">> => [<<"a">>, <<"b">>]
        }
    },
    Bin = ?M:canonicalise(Json),
    ?assertEqual({ok, Json}, ?M:parse(Bin)).

llama_pythonic_canonicalise_emits_python_literals_test() ->
    Bin = ?M:canonicalise(#{
        name => <<"f">>,
        arguments => #{<<"a">> => true, <<"b">> => null}
    }),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"True">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"None">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"true">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"null">>)).

%% =============================================================================
%% post_parse_mode + registry dispatch
%% =============================================================================

llama_pythonic_post_parse_mode_is_pythonic_test() ->
    ?assertEqual(pythonic, ?M:post_parse_mode()).

llama_pythonic_registry_dispatch_test() ->
    Spec = #{module => ?M},
    Bin = <<"[f(x=1)]">>,
    ?assertEqual(
        {ok, #{name => <<"f">>, arguments => #{<<"x">> => 1}}},
        barrel_inference_server_tool_format:parse(Spec, Bin)
    ).

llama_pythonic_shared_post_parse_mode_helper_test() ->
    Spec = #{module => ?M},
    ?assertEqual(
        pythonic,
        barrel_inference_server_tool_format:post_parse_mode(Spec)
    ).

%% Other families return `none' through the shared helper (the default
%% via `function_exported(.., post_parse_mode, 0)' check), so the new
%% post-parse path doesn't fire for them.
other_family_post_parse_mode_defaults_to_none_test() ->
    Spec = #{module => barrel_inference_server_tool_format_qwen_xml},
    ?assertEqual(
        none,
        barrel_inference_server_tool_format:post_parse_mode(Spec)
    ).

%% =============================================================================
%% family_name/0 + detect/1
%% =============================================================================

llama_pythonic_family_name_test() ->
    ?assertEqual(<<"llama-pythonic">>, ?M:family_name()).

llama_pythonic_detect_positive_test() ->
    Template = <<
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n"
        "When the user asks for a tool, respond in pythonic format: "
        "[func_name(arg=value)]<|eot_id|>"
    >>,
    ?assertEqual({detected, undefined}, ?M:detect(Template)).

llama_pythonic_detect_negative_with_python_tag_test() ->
    %% Llama 3.1 templates carry `<|python_tag|>'; they must keep
    %% detecting as `llama-python-tag', not as `llama-pythonic'.
    Template = <<"Use <|python_tag|>{...}<|eom_id|> to call. <|eot_id|>">>,
    ?assertEqual(not_detected, ?M:detect(Template)).

llama_pythonic_detect_negative_without_pythonic_mention_test() ->
    %% `<|eot_id|>' alone with no pythonic / python-list mention
    %% must NOT detect.
    Template = <<"Generic Llama template. <|eot_id|>">>,
    ?assertEqual(not_detected, ?M:detect(Template)).
