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
    schema_enum_alternation_is_parenthesised/1,
    schema_one_of_alternation_is_parenthesised/1,
    tool_with_enum_and_more_fields_parses/1,
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
        schema_enum_alternation_is_parenthesised,
        schema_one_of_alternation_is_parenthesised,
        tool_with_enum_and_more_fields_parses,
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
    %% root contains both text-response and tool-0 alternatives.
    ?assert(binary:match(G, <<"text-response">>) =/= nomatch),
    ?assert(binary:match(G, <<"tool-0">>) =/= nomatch).

required_omits_text_branch(_Cfg) ->
    Tools = [
        #{
            name => <<"search">>,
            description => <<>>,
            schema => #{<<"type">> => <<"object">>}
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, required),
    %% root must not include `text-response` on its right-hand side.
    {RootRhs, _} = root_body(G),
    ?assertEqual(nomatch, binary:match(RootRhs, <<"text-response">>)).

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

%% Regression for "failed to parse grammar" crash. GBNF `|` is
%% right-associative across the whole rule body, so the enum has to
%% be parenthesised: otherwise the alternation extends past the enum
%% values and absorbs trailing tokens (the field separator and the
%% closing brace), producing an invalid grammar llama.cpp refuses.
schema_enum_alternation_is_parenthesised(_Cfg) ->
    Schema = #{
        <<"type">> => <<"string">>,
        <<"enum">> => [<<"a">>, <<"b">>]
    },
    Bin = iolist_to_binary(erllama_server_grammar:schema_to_gbnf(Schema)),
    %% Enum body is wrapped in parens that immediately surround the
    %% alternation; specifically the literal string "(" then a quote
    %% must appear (allowing optional whitespace).
    ?assertMatch({match, _}, re:run(Bin, <<"\\(\\s*\"\\\\\"a\\\\\"\"">>)),
    ?assertMatch({match, _}, re:run(Bin, <<"\"\\\\\"b\\\\\"\"\\s*\\)">>)).

schema_one_of_alternation_is_parenthesised(_Cfg) ->
    Schema = #{
        <<"oneOf">> => [
            #{<<"type">> => <<"string">>},
            #{<<"type">> => <<"integer">>}
        ]
    },
    Bin = iolist_to_binary(erllama_server_grammar:schema_to_gbnf(Schema)),
    %% The oneOf body must start with `(` and end with `)`.
    ?assertMatch({match, _}, re:run(Bin, <<"\\(\\s*json-string\\s*\\|\\s*json-integer\\s*\\)">>)).

%% End-to-end: tool with an enum field followed by another required
%% field. The comma between fields must NOT be inside the enum
%% alternation. Mirrors mcp__barrel_memory__memory_extract's
%% "strategy" enum that triggered the parse failure with Claude Code.
tool_with_enum_and_more_fields_parses(_Cfg) ->
    Tools = [
        #{
            name => <<"extract">>,
            description => <<>>,
            schema => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"strategy">> => #{
                        <<"type">> => <<"string">>,
                        <<"enum">> => [
                            <<"discrete">>,
                            <<"summary">>,
                            <<"preference">>,
                            <<"all">>
                        ]
                    },
                    <<"session_id">> => #{<<"type">> => <<"string">>}
                },
                <<"required">> => [<<"strategy">>, <<"session_id">>]
            }
        }
    ],
    {ok, G} = erllama_server_grammar:from_tools(Tools, required),
    %% Each alternation branch in the enum must be a quoted literal
    %% (with the JSON escape `\"..\"`). After the very last branch
    %% there must be a `)` — i.e. no `|` should be followed by the
    %% field-separator literal `","` or by a closing brace, which
    %% would mean the alternation absorbed the surrounding tokens.
    ?assertEqual(
        nomatch,
        re:run(G, <<"\\|\\s*\"\\\\\",\\\\\"\"">>)
    ),
    ?assertEqual(
        nomatch,
        re:run(G, <<"\\|\\s*\"\\}\"">>)
    ),
    %% And the open-paren count must match the close-paren count:
    %% if the bug recurred the enum would emit `(` without `)`, or
    %% the surrounding object body would lose its closing brace.
    OpenCount = count_matches(G, <<"\\(">>),
    CloseCount = count_matches(G, <<"\\)">>),
    ?assertEqual(OpenCount, CloseCount).

count_matches(Bin, Pat) ->
    case re:run(Bin, Pat, [global]) of
        {match, L} -> length(L);
        nomatch -> 0
    end.

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
