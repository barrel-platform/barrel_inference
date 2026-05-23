%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_ollama_translate_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_inference_server.hrl").

%% =============================================================================
%% ollama_generate_to_internal/1
%% =============================================================================

generate_real_prompt_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<"hello">>
    }),
    ?assertEqual(<<"llama3">>, R#barrel_inference_request.model_id),
    ?assertEqual(<<"hello">>, R#barrel_inference_request.prompt),
    ?assertEqual(false, R#barrel_inference_request.is_preload),
    ?assertEqual(true, R#barrel_inference_request.stream).

generate_empty_prompt_is_preload_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>
    }),
    ?assertEqual(true, R#barrel_inference_request.is_preload),
    ?assertEqual(undefined, R#barrel_inference_request.prompt).

generate_missing_prompt_is_preload_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>
    }),
    ?assertEqual(true, R#barrel_inference_request.is_preload).

generate_keep_alive_seconds_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>,
        <<"keep_alive">> => 5
    }),
    ?assertEqual(5000, R#barrel_inference_request.keep_alive_ms).

generate_keep_alive_zero_unloads_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>,
        <<"keep_alive">> => 0
    }),
    ?assertEqual(0, R#barrel_inference_request.keep_alive_ms).

generate_keep_alive_negative_is_infinity_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>,
        <<"keep_alive">> => -1
    }),
    ?assertEqual(infinity, R#barrel_inference_request.keep_alive_ms).

generate_keep_alive_duration_string_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>,
        <<"keep_alive">> => <<"5m">>
    }),
    ?assertEqual(300000, R#barrel_inference_request.keep_alive_ms).

generate_keep_alive_unset_defaults_to_undefined_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<>>
    }),
    ?assertEqual(undefined, R#barrel_inference_request.keep_alive_ms).

generate_options_max_predict_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<"hi">>,
        <<"options">> => #{<<"num_predict">> => 50, <<"temperature">> => 0.5}
    }),
    ?assertEqual(50, R#barrel_inference_request.max_tokens),
    ?assert(abs(R#barrel_inference_request.temperature - 0.5) < 1.0e-6).

generate_stream_false_default_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_generate_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"prompt">> => <<"hi">>,
        <<"stream">> => false
    }),
    ?assertEqual(false, R#barrel_inference_request.stream).

generate_missing_model_test() ->
    ?assertMatch(
        {error, _},
        barrel_inference_server_translate:ollama_generate_to_internal(#{<<"prompt">> => <<"hi">>})
    ).

%% =============================================================================
%% ollama_chat_to_internal/1
%% =============================================================================

chat_real_messages_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_chat_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    ?assertEqual(false, R#barrel_inference_request.is_preload),
    ?assertEqual(1, length(R#barrel_inference_request.messages)).

chat_empty_messages_is_preload_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_chat_to_internal(#{
        <<"model">> => <<"llama3">>,
        <<"messages">> => []
    }),
    ?assertEqual(true, R#barrel_inference_request.is_preload).

chat_missing_messages_is_preload_test() ->
    {ok, R} = barrel_inference_server_translate:ollama_chat_to_internal(#{
        <<"model">> => <<"llama3">>
    }),
    ?assertEqual(true, R#barrel_inference_request.is_preload).

%% =============================================================================
%% parse_keep_alive/1
%% =============================================================================

keep_alive_parser_test_() ->
    Cases = [
        {undefined, undefined},
        {null, undefined},
        {0, 0},
        {<<"0">>, 0},
        {-1, infinity},
        {-300, infinity},
        {<<"-1">>, infinity},
        {5, 5000},
        {300, 300000},
        {<<"30s">>, 30000},
        {<<"5m">>, 300000},
        {<<"2h">>, 7200000},
        {<<"500ms">>, 500},
        {<<"junk">>, undefined}
    ],
    [
        ?_assertEqual(Expected, barrel_inference_server_translate:parse_keep_alive(Input))
     || {Input, Expected} <- Cases
    ].

%% =============================================================================
%% Response builders
%% =============================================================================

generate_chunk_shape_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:internal_to_ollama_generate_chunk(
            <<"Hello">>, <<"req-1">>, <<"llama3">>
        )
    ),
    M = json:decode(Bin),
    ?assertEqual(<<"llama3">>, maps:get(<<"model">>, M)),
    ?assertEqual(<<"Hello">>, maps:get(<<"response">>, M)),
    ?assertEqual(false, maps:get(<<"done">>, M)),
    ?assert(is_binary(maps:get(<<"created_at">>, M))).

generate_final_shape_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:internal_to_ollama_generate_final(
            #{finish_reason => stop, prompt_tokens => 5, completion_tokens => 3},
            <<"req-1">>,
            <<"llama3">>,
            #{total_duration_ns => 1000000, load_duration_ns => 500000}
        )
    ),
    M = json:decode(Bin),
    ?assertEqual(true, maps:get(<<"done">>, M)),
    ?assertEqual(<<"stop">>, maps:get(<<"done_reason">>, M)),
    ?assertEqual(1000000, maps:get(<<"total_duration">>, M)),
    ?assertEqual(500000, maps:get(<<"load_duration">>, M)),
    ?assertEqual(5, maps:get(<<"prompt_eval_count">>, M)),
    ?assertEqual(3, maps:get(<<"eval_count">>, M)).

preload_response_load_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:ollama_preload_response(
            generate,
            <<"load">>,
            <<"llama3">>,
            #{total_duration_ns => 100000, load_duration_ns => 100000}
        )
    ),
    M = json:decode(Bin),
    ?assertEqual(true, maps:get(<<"done">>, M)),
    ?assertEqual(<<"load">>, maps:get(<<"done_reason">>, M)),
    ?assertEqual(<<>>, maps:get(<<"response">>, M)).

preload_response_unload_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:ollama_preload_response(
            chat, <<"unload">>, <<"llama3">>, #{total_duration_ns => 100, load_duration_ns => 100}
        )
    ),
    M = json:decode(Bin),
    ?assertEqual(true, maps:get(<<"done">>, M)),
    ?assertEqual(<<"unload">>, maps:get(<<"done_reason">>, M)),
    ?assertEqual(
        #{<<"role">> => <<"assistant">>, <<"content">> => <<>>},
        maps:get(<<"message">>, M)
    ).

%% =============================================================================
%% ollama_embed_to_internal / legacy
%% =============================================================================

embed_string_input_test() ->
    {ok, #{model := M, inputs := In}} =
        barrel_inference_server_translate:ollama_embed_to_internal(#{
            <<"model">> => <<"em">>,
            <<"input">> => <<"hello">>
        }),
    ?assertEqual(<<"em">>, M),
    ?assertEqual([<<"hello">>], In).

embed_array_input_test() ->
    {ok, #{inputs := In}} =
        barrel_inference_server_translate:ollama_embed_to_internal(#{
            <<"model">> => <<"em">>,
            <<"input">> => [<<"a">>, <<"b">>]
        }),
    ?assertEqual([<<"a">>, <<"b">>], In).

embed_missing_model_test() ->
    ?assertMatch(
        {error, _},
        barrel_inference_server_translate:ollama_embed_to_internal(#{<<"input">> => <<"hi">>})
    ).

embed_missing_input_test() ->
    ?assertMatch(
        {error, missing_input},
        barrel_inference_server_translate:ollama_embed_to_internal(#{<<"model">> => <<"em">>})
    ).

embeddings_legacy_test() ->
    {ok, #{model := M, inputs := In}} =
        barrel_inference_server_translate:ollama_embeddings_legacy_to_internal(#{
            <<"model">> => <<"em">>,
            <<"prompt">> => <<"hi">>
        }),
    ?assertEqual(<<"em">>, M),
    ?assertEqual([<<"hi">>], In).

embed_response_shape_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:internal_to_ollama_embed_response(
            <<"em">>,
            [[0.1, 0.2], [0.3, 0.4]],
            8,
            #{total_duration_ns => 5000, load_duration_ns => 1000}
        )
    ),
    M = json:decode(Bin),
    ?assertEqual(<<"em">>, maps:get(<<"model">>, M)),
    ?assertEqual([[0.1, 0.2], [0.3, 0.4]], maps:get(<<"embeddings">>, M)),
    ?assertEqual(8, maps:get(<<"prompt_eval_count">>, M)),
    ?assertEqual(5000, maps:get(<<"total_duration">>, M)).

embeddings_legacy_response_test() ->
    Bin = iolist_to_binary(
        barrel_inference_server_translate:internal_to_ollama_embeddings_legacy_response(
            <<"em">>, [0.1, 0.2], #{}
        )
    ),
    M = json:decode(Bin),
    ?assertEqual([0.1, 0.2], maps:get(<<"embedding">>, M)).
