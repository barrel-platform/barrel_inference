%%% Tests for erllama_server_translate. Pure module: no erllama, no
%%% Cowboy, no I/O. We drive it with map literals.
-module(erllama_server_translate_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("erllama_server.hrl").

-export([all/0, groups/0, suite/0]).
-export([
    %% openai chat
    chat_minimal/1,
    chat_extracts_system/1,
    chat_streaming_flag/1,
    chat_temperature_default/1,
    chat_seed_optional/1,
    chat_stop_string_or_array/1,
    chat_tool_choice_required/1,
    chat_tool_choice_named/1,
    chat_tool_choice_none/1,
    chat_tools_normalise/1,
    chat_invalid_missing_model/1,
    chat_invalid_missing_messages/1,
    %% openai completion
    completion_minimal/1,
    completion_missing_prompt/1,
    %% openai embeddings
    embeddings_string_input/1,
    embeddings_array_input/1,
    embeddings_token_array_rejected/1,
    embeddings_missing_input/1,
    %% anthropic
    anthropic_minimal/1,
    anthropic_system_string/1,
    anthropic_system_blocks/1,
    anthropic_tools_normalise/1,
    anthropic_tool_choice_any_maps_required/1,
    anthropic_thinking_enabled/1,
    anthropic_content_string_passthrough/1,
    anthropic_content_blocks_flatten/1,
    anthropic_content_blocks_multiple_join/1,
    anthropic_content_blocks_drop_non_text/1,
    anthropic_content_blocks_tool_result/1,
    anthropic_content_blocks_empty/1,
    openai_content_blocks_flatten/1,
    %% response shapes
    openai_chat_response_shape/1,
    openai_chat_streaming_chunk_shape/1,
    openai_chat_final_shape/1,
    openai_completion_response_shape/1,
    openai_embedding_response_shape/1,
    anthropic_response_shape/1,
    anthropic_event_message_start/1,
    anthropic_event_text_delta/1,
    anthropic_event_message_delta/1
]).

%%====================================================================
%% CT setup
%%====================================================================

suite() -> [{timetrap, {seconds, 30}}].
groups() -> [].
all() ->
    [
        %% requests in
        chat_minimal,
        chat_extracts_system,
        chat_streaming_flag,
        chat_temperature_default,
        chat_seed_optional,
        chat_stop_string_or_array,
        chat_tool_choice_required,
        chat_tool_choice_named,
        chat_tool_choice_none,
        chat_tools_normalise,
        chat_invalid_missing_model,
        chat_invalid_missing_messages,
        completion_minimal,
        completion_missing_prompt,
        embeddings_string_input,
        embeddings_array_input,
        embeddings_token_array_rejected,
        embeddings_missing_input,
        anthropic_minimal,
        anthropic_system_string,
        anthropic_system_blocks,
        anthropic_tools_normalise,
        anthropic_tool_choice_any_maps_required,
        anthropic_thinking_enabled,
        anthropic_content_string_passthrough,
        anthropic_content_blocks_flatten,
        anthropic_content_blocks_multiple_join,
        anthropic_content_blocks_drop_non_text,
        anthropic_content_blocks_tool_result,
        anthropic_content_blocks_empty,
        openai_content_blocks_flatten,
        %% responses out
        openai_chat_response_shape,
        openai_chat_streaming_chunk_shape,
        openai_chat_final_shape,
        openai_completion_response_shape,
        openai_embedding_response_shape,
        anthropic_response_shape,
        anthropic_event_message_start,
        anthropic_event_text_delta,
        anthropic_event_message_delta
    ].

%%====================================================================
%% OpenAI chat
%%====================================================================

chat_minimal(_Cfg) ->
    Body = #{
        <<"model">> => <<"gpt-4o">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => <<"hi">>
            }
        ]
    },
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(<<"gpt-4o">>, R#erllama_request.model_id),
    ?assertEqual(openai, R#erllama_request.api),
    ?assertEqual(
        [#{role => <<"user">>, content => <<"hi">>}],
        R#erllama_request.messages
    ),
    ?assertEqual(undefined, R#erllama_request.system),
    ?assertEqual(false, R#erllama_request.stream),
    ?assertEqual(1024, R#erllama_request.max_tokens).

chat_extracts_system(_Cfg) ->
    Body = #{
        <<"model">> => <<"x">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"sys1">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"u1">>},
            #{<<"role">> => <<"system">>, <<"content">> => <<"sys2">>}
        ]
    },
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(<<"sys1\n\nsys2">>, R#erllama_request.system),
    ?assertEqual(1, length(R#erllama_request.messages)).

chat_streaming_flag(_Cfg) ->
    Body = (base_chat())#{<<"stream">> => true},
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(true, R#erllama_request.stream).

chat_temperature_default(_Cfg) ->
    {ok, R} = erllama_server_translate:openai_chat_to_internal(base_chat()),
    ?assertEqual(1.0, R#erllama_request.temperature).

chat_seed_optional(_Cfg) ->
    {ok, R1} = erllama_server_translate:openai_chat_to_internal(base_chat()),
    {ok, R2} = erllama_server_translate:openai_chat_to_internal(
        (base_chat())#{<<"seed">> => 42}
    ),
    ?assertEqual(undefined, R1#erllama_request.seed),
    ?assertEqual(42, R2#erllama_request.seed).

chat_stop_string_or_array(_Cfg) ->
    {ok, R1} = erllama_server_translate:openai_chat_to_internal(
        (base_chat())#{<<"stop">> => <<"END">>}
    ),
    {ok, R2} = erllama_server_translate:openai_chat_to_internal(
        (base_chat())#{<<"stop">> => [<<"a">>, <<"b">>]}
    ),
    ?assertEqual([<<"END">>], R1#erllama_request.stop),
    ?assertEqual([<<"a">>, <<"b">>], R2#erllama_request.stop).

chat_tool_choice_required(_Cfg) ->
    Body = (base_chat())#{<<"tool_choice">> => <<"required">>},
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(required, R#erllama_request.tool_choice).

chat_tool_choice_named(_Cfg) ->
    Body = (base_chat())#{
        <<"tool_choice">> =>
            #{
                <<"type">> => <<"function">>,
                <<"function">> => #{<<"name">> => <<"search">>}
            }
    },
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual({named, <<"search">>}, R#erllama_request.tool_choice).

chat_tool_choice_none(_Cfg) ->
    Body = (base_chat())#{<<"tool_choice">> => <<"none">>},
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertEqual(none, R#erllama_request.tool_choice).

chat_tools_normalise(_Cfg) ->
    Body = (base_chat())#{
        <<"tools">> => [
            #{
                <<"type">> => <<"function">>,
                <<"function">> => #{
                    <<"name">> => <<"search">>,
                    <<"description">> => <<"web search">>,
                    <<"parameters">> => #{<<"type">> => <<"object">>}
                }
            }
        ]
    },
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    [Tool] = R#erllama_request.tools,
    ?assertEqual(<<"search">>, maps:get(name, Tool)),
    ?assertEqual(<<"web search">>, maps:get(description, Tool)),
    ?assertMatch(#{<<"type">> := <<"object">>}, maps:get(schema, Tool)).

chat_invalid_missing_model(_Cfg) ->
    Body = #{
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => <<"x">>
            }
        ]
    },
    ?assertMatch(
        {error, {missing_field, <<"model">>}},
        erllama_server_translate:openai_chat_to_internal(Body)
    ).

chat_invalid_missing_messages(_Cfg) ->
    ?assertMatch(
        {error, {missing_field, <<"messages">>}},
        erllama_server_translate:openai_chat_to_internal(
            #{<<"model">> => <<"x">>}
        )
    ).

%%====================================================================
%% OpenAI legacy completions
%%====================================================================

completion_minimal(_Cfg) ->
    Body = #{<<"model">> => <<"x">>, <<"prompt">> => <<"hi">>},
    {ok, R} = erllama_server_translate:openai_completion_to_internal(Body),
    ?assertEqual(<<"x">>, R#erllama_request.model_id),
    ?assertEqual(<<"hi">>, R#erllama_request.prompt),
    ?assertEqual([], R#erllama_request.messages),
    ?assertEqual(none, R#erllama_request.tool_choice).

completion_missing_prompt(_Cfg) ->
    ?assertMatch(
        {error, {missing_field, <<"prompt">>}},
        erllama_server_translate:openai_completion_to_internal(
            #{<<"model">> => <<"x">>}
        )
    ).

%%====================================================================
%% OpenAI embeddings
%%====================================================================

embeddings_string_input(_Cfg) ->
    {ok, R} = erllama_server_translate:openai_embeddings_to_internal(
        #{<<"model">> => <<"e">>, <<"input">> => <<"hello">>}
    ),
    ?assertEqual(<<"e">>, maps:get(model, R)),
    ?assertEqual([<<"hello">>], maps:get(inputs, R)).

embeddings_array_input(_Cfg) ->
    {ok, R} = erllama_server_translate:openai_embeddings_to_internal(
        #{
            <<"model">> => <<"e">>,
            <<"input">> => [<<"a">>, <<"b">>]
        }
    ),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(inputs, R)).

embeddings_token_array_rejected(_Cfg) ->
    ?assertMatch(
        {error, unsupported_input_type},
        erllama_server_translate:openai_embeddings_to_internal(
            #{<<"model">> => <<"e">>, <<"input">> => [1, 2, 3]}
        )
    ).

embeddings_missing_input(_Cfg) ->
    ?assertMatch(
        {error, missing_input},
        erllama_server_translate:openai_embeddings_to_internal(
            #{<<"model">> => <<"e">>}
        )
    ).

%%====================================================================
%% Anthropic
%%====================================================================

anthropic_minimal(_Cfg) ->
    Body = #{
        <<"model">> => <<"claude">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(anthropic, R#erllama_request.api),
    ?assertEqual(<<"claude">>, R#erllama_request.model_id),
    ?assertEqual(undefined, R#erllama_request.system).

anthropic_system_string(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"system">> => <<"be helpful">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(<<"be helpful">>, R#erllama_request.system).

anthropic_system_blocks(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"system">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"part1">>},
            #{<<"type">> => <<"text">>, <<"text">> => <<"part2">>}
        ],
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(<<"part1\n\npart2">>, R#erllama_request.system).

anthropic_tools_normalise(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"tools">> => [
            #{
                <<"name">> => <<"search">>,
                <<"description">> => <<"d">>,
                <<"input_schema">> => #{<<"type">> => <<"object">>}
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    [Tool] = R#erllama_request.tools,
    ?assertEqual(<<"search">>, maps:get(name, Tool)).

anthropic_tool_choice_any_maps_required(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"tool_choice">> => #{<<"type">> => <<"any">>}
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(required, R#erllama_request.tool_choice).

anthropic_thinking_enabled(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"thinking">> => #{<<"type">> => <<"enabled">>}
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(enabled, R#erllama_request.thinking).

%% Bare-string content is the simple Anthropic shape; must survive
%% the flattening helper unchanged so OpenAI Python / curl examples
%% keep working.
anthropic_content_string_passthrough(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"hi">>}],
        R#erllama_request.messages
    ).

%% Single Anthropic content block. Claude Code sends this on every
%% turn; before the fix this crashed nif_apply_chat_template/2 with
%% badarg because the NIF only handles binary content.
anthropic_content_blocks_flatten(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"hello">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"hello">>}],
        R#erllama_request.messages
    ).

anthropic_content_blocks_multiple_join(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"part1">>},
                    #{<<"type">> => <<"text">>, <<"text">> => <<"part2">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"part1 part2">>}],
        R#erllama_request.messages
    ).

%% Image / unknown blocks drop out; the text block is retained.
%% Multimodal isn't wired through to the NIF yet, so dropping is the
%% right default rather than passing structured maps the template
%% engine can't render.
anthropic_content_blocks_drop_non_text(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"image">>,
                        <<"source">> => #{
                            <<"type">> => <<"base64">>,
                            <<"media_type">> => <<"image/png">>,
                            <<"data">> => <<"...">>
                        }
                    },
                    #{<<"type">> => <<"text">>, <<"text">> => <<"describe">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"describe">>}],
        R#erllama_request.messages
    ).

%% tool_result is a wrapping block whose `content` is itself either
%% a binary or a nested block list. Both shapes flatten to plain text
%% so the assistant turn can be rendered by the template.
anthropic_content_blocks_tool_result(_Cfg) ->
    BodyA = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"tool_result">>,
                        <<"tool_use_id">> => <<"tool-1">>,
                        <<"content">> => <<"ok">>
                    }
                ]
            }
        ]
    },
    {ok, RA} = erllama_server_translate:anthropic_messages_to_internal(BodyA),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"ok">>}],
        RA#erllama_request.messages
    ),
    BodyB = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"tool_result">>,
                        <<"tool_use_id">> => <<"tool-1">>,
                        <<"content">> => [
                            #{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}
                        ]
                    }
                ]
            }
        ]
    },
    {ok, RB} = erllama_server_translate:anthropic_messages_to_internal(BodyB),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"ok">>}],
        RB#erllama_request.messages
    ).

anthropic_content_blocks_empty(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => []}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<>>}],
        R#erllama_request.messages
    ).

%% The same translator path serves OpenAI multimodal content. Confirm
%% the helper flattens that too so /v1/chat/completions with typed
%% blocks does not hit the same NIF crash.
openai_content_blocks_flatten(_Cfg) ->
    Body = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"x">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:openai_chat_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"x">>}],
        R#erllama_request.messages
    ).

%%====================================================================
%% Response shapes
%%====================================================================

openai_chat_response_shape(_Cfg) ->
    Stats = #{
        prompt_tokens => 5,
        completion_tokens => 3,
        finish_reason => stop
    },
    R = erllama_server_translate:internal_to_openai_chat_response(
        <<"hello">>, Stats, <<"gpt-4o">>
    ),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, R)),
    ?assertEqual(<<"gpt-4o">>, maps:get(<<"model">>, R)),
    [Choice] = maps:get(<<"choices">>, R),
    ?assertEqual(
        <<"hello">>,
        maps:get(
            <<"content">>,
            maps:get(<<"message">>, Choice)
        )
    ),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    Usage = maps:get(<<"usage">>, R),
    ?assertEqual(8, maps:get(<<"total_tokens">>, Usage)).

openai_chat_streaming_chunk_shape(_Cfg) ->
    Iolist = erllama_server_translate:internal_to_openai_chat_chunk(
        <<"hi">>, <<"chatcmpl-1">>, <<"gpt-4o">>
    ),
    Decoded = json:decode(iolist_to_binary(Iolist)),
    ?assertEqual(<<"chat.completion.chunk">>, maps:get(<<"object">>, Decoded)),
    [Ch] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(
        <<"hi">>,
        maps:get(<<"content">>, maps:get(<<"delta">>, Ch))
    ),
    ?assertEqual(null, maps:get(<<"finish_reason">>, Ch)).

openai_chat_final_shape(_Cfg) ->
    Stats = #{prompt_tokens => 1, completion_tokens => 2, finish_reason => length},
    Iolist = erllama_server_translate:internal_to_openai_chat_final(
        Stats, <<"chatcmpl-1">>, <<"gpt-4o">>
    ),
    Decoded = json:decode(iolist_to_binary(Iolist)),
    [Ch] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(<<"length">>, maps:get(<<"finish_reason">>, Ch)),
    ?assertEqual(#{}, maps:get(<<"delta">>, Ch)),
    ?assertEqual(
        3,
        maps:get(
            <<"total_tokens">>,
            maps:get(<<"usage">>, Decoded)
        )
    ).

openai_completion_response_shape(_Cfg) ->
    R = erllama_server_translate:internal_to_openai_completion_response(
        <<"out">>,
        #{
            prompt_tokens => 1,
            completion_tokens => 1,
            finish_reason => stop
        },
        <<"m">>
    ),
    ?assertEqual(<<"text_completion">>, maps:get(<<"object">>, R)),
    [Choice] = maps:get(<<"choices">>, R),
    ?assertEqual(<<"out">>, maps:get(<<"text">>, Choice)).

openai_embedding_response_shape(_Cfg) ->
    R = erllama_server_translate:internal_to_openai_embedding_response(
        [[1.0, 2.0], [3.0, 4.0]], 7, <<"e">>
    ),
    ?assertEqual(<<"list">>, maps:get(<<"object">>, R)),
    [#{<<"index">> := I0} | _] = Data = maps:get(<<"data">>, R),
    ?assertEqual(0, I0),
    ?assertEqual(2, length(Data)).

anthropic_response_shape(_Cfg) ->
    Stats = #{
        prompt_tokens => 5,
        completion_tokens => 3,
        finish_reason => stop
    },
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        <<"hi">>, Stats, <<"claude">>
    ),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, R)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, R)),
    [Block] = maps:get(<<"content">>, R),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"hi">>, maps:get(<<"text">>, Block)).

anthropic_event_message_start(_Cfg) ->
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        message_start, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: message_start">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"id\":\"msg_1\"">>) =/= nomatch).

anthropic_event_text_delta(_Cfg) ->
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {text_delta, <<"hello">>}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"text\":\"hello\"">>) =/= nomatch).

anthropic_event_message_delta(_Cfg) ->
    Stats = #{completion_tokens => 4, finish_reason => length},
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: message_delta">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"stop_reason\":\"max_tokens\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"output_tokens\":4">>) =/= nomatch).

%%====================================================================
%% Helpers
%%====================================================================

base_chat() ->
    #{
        <<"model">> => <<"x">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }.
