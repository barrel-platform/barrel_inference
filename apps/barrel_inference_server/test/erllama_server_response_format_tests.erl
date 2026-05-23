%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_response_format_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erllama_server.hrl").

%% =============================================================================
%% parse_response_format_openai/1
%% =============================================================================

openai_text_default_test() ->
    ?assertEqual(text, erllama_server_translate:parse_response_format_openai(undefined)),
    ?assertEqual(text, erllama_server_translate:parse_response_format_openai(null)),
    ?assertEqual(
        text,
        erllama_server_translate:parse_response_format_openai(#{<<"type">> => <<"text">>})
    ).

openai_json_object_test() ->
    ?assertEqual(
        json_object,
        erllama_server_translate:parse_response_format_openai(
            #{<<"type">> => <<"json_object">>}
        )
    ).

openai_json_schema_test() ->
    Body = #{
        <<"type">> => <<"json_schema">>,
        <<"json_schema">> => #{
            <<"name">> => <<"person">>,
            <<"schema">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}},
                <<"required">> => [<<"name">>]
            }
        }
    },
    ?assertMatch(
        {json_schema, #{<<"type">> := <<"object">>}},
        erllama_server_translate:parse_response_format_openai(Body)
    ).

openai_garbage_falls_back_to_text_test() ->
    ?assertEqual(
        text,
        erllama_server_translate:parse_response_format_openai(#{<<"type">> => <<"unknown">>})
    ),
    ?assertEqual(
        text,
        erllama_server_translate:parse_response_format_openai(<<"not a map">>)
    ).

%% =============================================================================
%% parse_response_format_ollama/1
%% =============================================================================

ollama_format_json_test() ->
    ?assertEqual(
        json_object,
        erllama_server_translate:parse_response_format_ollama(<<"json">>)
    ).

ollama_format_schema_map_test() ->
    Schema = #{<<"type">> => <<"object">>},
    ?assertEqual(
        {json_schema, Schema},
        erllama_server_translate:parse_response_format_ollama(Schema)
    ).

ollama_format_undef_is_text_test() ->
    ?assertEqual(text, erllama_server_translate:parse_response_format_ollama(undefined)),
    ?assertEqual(text, erllama_server_translate:parse_response_format_ollama(null)),
    ?assertEqual(text, erllama_server_translate:parse_response_format_ollama(<<>>)).

%% =============================================================================
%% Translator pickups
%% =============================================================================

openai_chat_response_format_test() ->
    {ok, R} = erllama_server_translate:openai_chat_to_internal(#{
        <<"model">> => <<"m">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"response_format">> => #{<<"type">> => <<"json_object">>}
    }),
    ?assertEqual(json_object, R#erllama_request.response_format).

ollama_generate_format_picks_up_test() ->
    {ok, R} = erllama_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"m">>,
        <<"prompt">> => <<"hi">>,
        <<"format">> => <<"json">>
    }),
    ?assertEqual(json_object, R#erllama_request.response_format).

ollama_chat_format_schema_test() ->
    {ok, R} = erllama_server_translate:ollama_chat_to_internal(#{
        <<"model">> => <<"m">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"format">> => #{<<"type">> => <<"object">>}
    }),
    ?assertMatch({json_schema, _}, R#erllama_request.response_format).

%% =============================================================================
%% Grammar
%% =============================================================================

grammar_text_returns_empty_test() ->
    ?assertEqual({ok, <<>>}, erllama_server_grammar:from_response_format(text)).

grammar_json_object_returns_value_grammar_test() ->
    {ok, G} = erllama_server_grammar:from_response_format(json_object),
    ?assert(is_binary(G)),
    ?assert(byte_size(G) > 0),
    ?assert(binary:match(G, <<"root">>) =/= nomatch),
    ?assert(binary:match(G, <<"value">>) =/= nomatch).

grammar_json_schema_object_test() ->
    Schema = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"name">> => #{<<"type">> => <<"string">>},
            <<"age">> => #{<<"type">> => <<"integer">>}
        },
        <<"required">> => [<<"name">>]
    },
    {ok, G} = erllama_server_grammar:from_response_format({json_schema, Schema}),
    ?assert(is_binary(G)),
    ?assert(byte_size(G) > 0).

grammar_json_schema_string_test() ->
    Schema = #{<<"type">> => <<"string">>},
    {ok, G} = erllama_server_grammar:from_response_format({json_schema, Schema}),
    ?assert(byte_size(G) > 0).
