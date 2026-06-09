%%% Tests for barrel_inference_server_grammar. Pure module: no llama.cpp at
%%% test time. We compile the GBNF output and check structural
%%% properties (top-level rules, embedded literals, branches).
-module(barrel_inference_server_grammar_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0]).
-export([
    schema_object_with_required/1,
    schema_array_emits_brackets/1,
    schema_enum_lists_alternatives/1,
    schema_enum_alternation_is_parenthesised/1,
    schema_one_of_alternation_is_parenthesised/1
]).

suite() -> [{timetrap, {seconds, 30}}].
all() ->
    [
        schema_object_with_required,
        schema_array_emits_brackets,
        schema_enum_lists_alternatives,
        schema_enum_alternation_is_parenthesised,
        schema_one_of_alternation_is_parenthesised
    ].

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
    Bin = iolist_to_binary(barrel_inference_server_grammar:schema_to_gbnf(Schema)),
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
    Bin = iolist_to_binary(barrel_inference_server_grammar:schema_to_gbnf(Schema)),
    ?assert(binary:match(Bin, <<"\"[\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"]\"">>) =/= nomatch).

schema_enum_lists_alternatives(_Cfg) ->
    Schema = #{
        <<"type">> => <<"string">>,
        <<"enum">> => [<<"a">>, <<"b">>, <<"c">>]
    },
    Bin = iolist_to_binary(barrel_inference_server_grammar:schema_to_gbnf(Schema)),
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
    Bin = iolist_to_binary(barrel_inference_server_grammar:schema_to_gbnf(Schema)),
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
    Bin = iolist_to_binary(barrel_inference_server_grammar:schema_to_gbnf(Schema)),
    %% The oneOf body must start with `(` and end with `)`.
    ?assertMatch({match, _}, re:run(Bin, <<"\\(\\s*json-string\\s*\\|\\s*json-integer\\s*\\)">>)).
