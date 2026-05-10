%%% Tests for erllama_server_grammar. Pure module: no llama.cpp at
%%% test time. We compile the GBNF output and check structural
%%% properties (top-level rules, embedded literals, branches).
-module(erllama_server_grammar_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0]).
-export([
    no_tools_returns_empty/1,
    empty_tools_returns_empty/1,
    tool_choice_none_returns_empty/1,
    auto_emits_text_or_tool/1,
    required_omits_text_branch/1,
    named_pins_to_tool/1,
    named_unknown_returns_error/1,
    schema_object_with_required/1,
    schema_array_emits_brackets/1,
    schema_enum_lists_alternatives/1,
    output_includes_root_rule/1,
    output_includes_tool_name_literal/1
]).

suite() -> [{timetrap, {seconds, 30}}].
all() ->
    [
        no_tools_returns_empty,
        empty_tools_returns_empty,
        tool_choice_none_returns_empty,
        auto_emits_text_or_tool,
        required_omits_text_branch,
        named_pins_to_tool,
        named_unknown_returns_error,
        schema_object_with_required,
        schema_array_emits_brackets,
        schema_enum_lists_alternatives,
        output_includes_root_rule,
        output_includes_tool_name_literal
    ].

%%====================================================================
%% no-grammar paths
%%====================================================================

no_tools_returns_empty(_Cfg) ->
    ?assertEqual({ok, <<>>}, erllama_server_grammar:from_tools(undefined, auto)).

empty_tools_returns_empty(_Cfg) ->
    ?assertEqual({ok, <<>>}, erllama_server_grammar:from_tools([], auto)).

tool_choice_none_returns_empty(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    ?assertEqual({ok, <<>>}, erllama_server_grammar:from_tools(Tools, none)).

%%====================================================================
%% top-level rule shape
%%====================================================================

auto_emits_text_or_tool(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, auto),
    %% root contains both text_response and tool_0 alternatives.
    ?assert(binary:match(G, <<"text_response">>) =/= nomatch),
    ?assert(binary:match(G, <<"tool_0">>) =/= nomatch).

required_omits_text_branch(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, required),
    %% root must not include `text_response` on its right-hand side.
    {RootRhs, _} = root_body(G),
    ?assertEqual(nomatch, binary:match(RootRhs, <<"text_response">>)).

named_pins_to_tool(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        },
        #{
            name => <<"book">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, {named, <<"book">>}),
    {RootRhs, _} = root_body(G),
    ?assertEqual(nomatch, binary:match(RootRhs, <<"|">>)).

named_unknown_returns_error(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    ?assertMatch(
        {error, {unknown_tool, <<"missing">>}},
        erllama_server_grammar:from_tools(
            Tools, {named, <<"missing">>}
        )
    ).

%%====================================================================
%% schema fragments
%%====================================================================

schema_object_with_required(_Cfg) ->
    Schema = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"q">> => #{<<"type">> => <<"string">>},
            <<"limit">> => #{<<"type">> => <<"integer">>}
        },
        <<"required">> => [<<"q">>]
    },
    Bin = iolist_to_binary(erllama_server_grammar:schema_to_gbnf(Schema)),
    %% A property name appears as a JSON-quoted literal.
    ?assert(binary:match(Bin, <<"\\\"q\\\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\\\"limit\\\"">>) =/= nomatch),
    %% Object braces present.
    ?assert(binary:match(Bin, <<"\"{\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"}\"">>) =/= nomatch).

schema_array_emits_brackets(_Cfg) ->
    Schema = #{
        <<"type">> => <<"array">>,
        <<"items">> => #{<<"type">> => <<"string">>}
    },
    Bin = iolist_to_binary(erllama_server_grammar:schema_to_gbnf(Schema)),
    ?assert(binary:match(Bin, <<"\"[\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"]\"">>) =/= nomatch).

schema_enum_lists_alternatives(_Cfg) ->
    Schema = #{
        <<"type">> => <<"string">>,
        <<"enum">> => [<<"a">>, <<"b">>, <<"c">>]
    },
    Bin = iolist_to_binary(erllama_server_grammar:schema_to_gbnf(Schema)),
    ?assert(binary:match(Bin, <<"\\\"a\\\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\\\"b\\\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\\\"c\\\"">>) =/= nomatch),
    %% Three alternatives means at least two `|` characters.
    {match, Pipes} = re:run(Bin, <<"\\|">>, [global]),
    ?assert(length(Pipes) >= 2).

%%====================================================================
%% Output well-formedness
%%====================================================================

output_includes_root_rule(_Cfg) ->
    Tools = [
        #{
            name => <<"x">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, auto),
    ?assertMatch({_, _}, root_body(G)).

output_includes_tool_name_literal(_Cfg) ->
    Tools = [
        #{
            name => <<"my_tool">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, auto),
    %% Tool name appears as an embedded JSON string literal.
    ?assert(binary:match(G, <<"\\\"my_tool\\\"">>) =/= nomatch).

%%====================================================================
%% Helpers
%%====================================================================

%% Find the line `root ::= <body>\n` and return {Body, Rest}.
root_body(G) ->
    case
        re:run(
            G,
            <<"^root ::= ([^\\n]*)\\n">>,
            [{capture, all_but_first, binary}, multiline]
        )
    of
        {match, [Body]} -> {Body, <<>>};
        nomatch -> ct:fail({no_root_rule, G})
    end.
