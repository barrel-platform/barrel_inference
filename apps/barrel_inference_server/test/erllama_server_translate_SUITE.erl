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
    anthropic_tool_choice_none/1,
    anthropic_thinking_enabled/1,
    anthropic_stop_sequences_parsed/1,
    anthropic_metadata_user_id_captured/1,
    anthropic_metadata_user_id_absent_or_bad/1,
    anthropic_content_string_passthrough/1,
    anthropic_content_blocks_flatten/1,
    anthropic_content_blocks_multiple_join/1,
    anthropic_content_blocks_drop_non_text/1,
    anthropic_content_blocks_tool_result/1,
    anthropic_content_blocks_assistant_tool_use_marker/1,
    anthropic_content_blocks_drop_engine_unsupported/1,
    anthropic_content_blocks_empty/1,
    openai_content_blocks_flatten/1,
    anthropic_cache_control_captured_on_system/1,
    anthropic_cache_control_captured_on_tool/1,
    anthropic_cache_control_captured_on_message_block/1,
    anthropic_no_cache_hints_when_unmarked/1,
    anthropic_cache_hints_hash_is_stable/1,
    anthropic_usage_emits_cache_read_on_exact_hit/1,
    anthropic_usage_emits_cache_creation_on_cold/1,
    openai_usage_emits_cached_tokens_on_exact_hit/1,
    %% response shapes
    openai_chat_response_shape/1,
    openai_chat_streaming_chunk_shape/1,
    openai_chat_final_shape/1,
    openai_completion_response_shape/1,
    openai_embedding_response_shape/1,
    anthropic_response_shape/1,
    anthropic_response_tool_use_block/1,
    anthropic_response_emits_stop_sequence_when_matched/1,
    anthropic_response_omits_stop_sequence_on_natural_stop/1,
    anthropic_event_message_delta_emits_stop_sequence/1,
    anthropic_response_thinking_block_with_signature/1,
    anthropic_response_thinking_then_text_blocks/1,
    anthropic_event_message_start/1,
    anthropic_event_text_delta/1,
    anthropic_event_content_block_index_threads_through/1,
    anthropic_event_message_delta/1,
    anthropic_event_message_delta_emits_cache_read_on_exact_hit/1,
    anthropic_event_message_delta_emits_cache_creation_on_cold/1,
    anthropic_event_message_delta_emits_cache_creation_nested_5m/1,
    anthropic_event_message_delta_emits_cache_creation_nested_1h/1
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
        anthropic_tool_choice_none,
        anthropic_thinking_enabled,
        anthropic_stop_sequences_parsed,
        anthropic_metadata_user_id_captured,
        anthropic_metadata_user_id_absent_or_bad,
        anthropic_content_string_passthrough,
        anthropic_content_blocks_flatten,
        anthropic_content_blocks_multiple_join,
        anthropic_content_blocks_drop_non_text,
        anthropic_content_blocks_tool_result,
        anthropic_content_blocks_assistant_tool_use_marker,
        anthropic_content_blocks_drop_engine_unsupported,
        anthropic_content_blocks_empty,
        openai_content_blocks_flatten,
        anthropic_cache_control_captured_on_system,
        anthropic_cache_control_captured_on_tool,
        anthropic_cache_control_captured_on_message_block,
        anthropic_no_cache_hints_when_unmarked,
        anthropic_cache_hints_hash_is_stable,
        anthropic_usage_emits_cache_read_on_exact_hit,
        anthropic_usage_emits_cache_creation_on_cold,
        openai_usage_emits_cached_tokens_on_exact_hit,
        %% responses out
        openai_chat_response_shape,
        openai_chat_streaming_chunk_shape,
        openai_chat_final_shape,
        openai_completion_response_shape,
        openai_embedding_response_shape,
        anthropic_response_shape,
        anthropic_response_tool_use_block,
        anthropic_response_emits_stop_sequence_when_matched,
        anthropic_response_omits_stop_sequence_on_natural_stop,
        anthropic_event_message_delta_emits_stop_sequence,
        anthropic_response_thinking_block_with_signature,
        anthropic_response_thinking_then_text_blocks,
        anthropic_event_message_start,
        anthropic_event_text_delta,
        anthropic_event_content_block_index_threads_through,
        anthropic_event_message_delta,
        anthropic_event_message_delta_emits_cache_read_on_exact_hit,
        anthropic_event_message_delta_emits_cache_creation_on_cold,
        anthropic_event_message_delta_emits_cache_creation_nested_5m,
        anthropic_event_message_delta_emits_cache_creation_nested_1h
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

%% `tool_choice: "none"` must round-trip to the `none` atom so the
%% grammar layer skips installing a GBNF. The pre-fix catch-all
%% silently downgraded it to `auto`.
anthropic_tool_choice_none(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"tool_choice">> => #{<<"type">> => <<"none">>}
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(none, R#erllama_request.tool_choice).

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

%% Anthropic uses `stop_sequences` (plural). Previously the translator
%% read only `stop` (OpenAI naming) so Anthropic clients lost their
%% stop tokens silently.
anthropic_stop_sequences_parsed(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"stop_sequences">> => [<<"\n\nHuman:">>, <<"END">>]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual([<<"\n\nHuman:">>, <<"END">>], R#erllama_request.stop).

%% Anthropic clients may pass metadata.user_id for support
%% diagnostics. We capture it on the request record so downstream
%% observability hooks can read it; no engine pass-through yet.
anthropic_metadata_user_id_captured(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ],
        <<"metadata">> => #{<<"user_id">> => <<"u-42">>}
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual(<<"u-42">>, R#erllama_request.user_id).

%% Absent metadata leaves the field undefined; non-binary user_id is
%% ignored rather than crashing.
anthropic_metadata_user_id_absent_or_bad(_Cfg) ->
    Body0 = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ]
    },
    {ok, R0} = erllama_server_translate:anthropic_messages_to_internal(Body0),
    ?assertEqual(undefined, R0#erllama_request.user_id),
    Body1 = Body0#{<<"metadata">> => #{<<"user_id">> => 42}},
    {ok, R1} = erllama_server_translate:anthropic_messages_to_internal(Body1),
    ?assertEqual(undefined, R1#erllama_request.user_id).

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

%% Assistant turn with a tool_use block (from a prior round) should
%% serialise to a stable marker, not be silently dropped, so the
%% template input preserves the fact that a tool was called.
anthropic_content_blocks_assistant_tool_use_marker(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"assistant">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"tool_use">>,
                        <<"id">> => <<"toolu_42">>,
                        <<"name">> => <<"search">>,
                        <<"input">> => #{<<"q">> => <<"x">>}
                    }
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    [#{content := C}] = R#erllama_request.messages,
    ?assert(binary:match(C, <<"[tool_call">>) =/= nomatch),
    ?assert(binary:match(C, <<"name=search">>) =/= nomatch),
    ?assert(binary:match(C, <<"id=toolu_42">>) =/= nomatch).

%% Blocks the engine cannot consume (document, thinking,
%% redacted_thinking, server_tool_use, search_result,
%% web_search_tool_result) drop with no text contribution. Explicit
%% clauses, not catch-all silent drops.
anthropic_content_blocks_drop_engine_unsupported(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"document">>, <<"source">> => #{}},
                    #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"…">>},
                    #{
                        <<"type">> => <<"redacted_thinking">>,
                        <<"data">> => <<"x">>
                    },
                    #{<<"type">> => <<"server_tool_use">>},
                    #{<<"type">> => <<"web_search_tool_result">>},
                    #{<<"type">> => <<"search_result">>},
                    #{<<"type">> => <<"text">>, <<"text">> => <<"go">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch(
        [#{role := <<"user">>, content := <<"go">>}],
        R#erllama_request.messages
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

%% Anthropic prompt-caching markers are captured into
%% cache_hints. The translator does NOT alter the system / messages
%% content; markers only flow through to the response builder so
%% usage counters can credit hits.
anthropic_cache_control_captured_on_system(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"system">> => [
            #{
                <<"type">> => <<"text">>,
                <<"text">> => <<"persona">>,
                <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}
            }
        ],
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    Hints = R#erllama_request.cache_hints,
    ?assertEqual(1, length(Hints)),
    [#{kind := Kind, hash := Hash}] = Hints,
    ?assertEqual(system, Kind),
    ?assertEqual(32, byte_size(Hash)).

anthropic_cache_control_captured_on_tool(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ],
        <<"tools">> => [
            #{
                <<"name">> => <<"search">>,
                <<"description">> => <<"d">>,
                <<"input_schema">> => #{<<"type">> => <<"object">>},
                <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch([#{kind := tool}], R#erllama_request.cache_hints).

anthropic_cache_control_captured_on_message_block(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"text">>,
                        <<"text">> => <<"big context">>,
                        <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}
                    },
                    #{<<"type">> => <<"text">>, <<"text">> => <<"now do x">>}
                ]
            }
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertMatch([#{kind := message}], R#erllama_request.cache_hints).

anthropic_no_cache_hints_when_unmarked(_Cfg) ->
    Body = #{
        <<"model">> => <<"c">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ]
    },
    {ok, R} = erllama_server_translate:anthropic_messages_to_internal(Body),
    ?assertEqual([], R#erllama_request.cache_hints).

%% The hash depends only on block content, not on the order of map
%% keys (Erlang map iteration order is unspecified) and not on the
%% cache_control TTL field. Same content -> same hash across turns.
anthropic_cache_hints_hash_is_stable(_Cfg) ->
    SystemA = [
        #{
            <<"text">> => <<"persona">>,
            <<"type">> => <<"text">>,
            <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}
        }
    ],
    SystemB = [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => <<"persona">>,
            <<"cache_control">> => #{<<"type">> => <<"ephemeral">>, <<"ttl">> => <<"1h">>}
        }
    ],
    BodyA = #{
        <<"model">> => <<"c">>,
        <<"system">> => SystemA,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"x">>}
        ]
    },
    BodyB = BodyA#{<<"system">> => SystemB},
    {ok, RA} = erllama_server_translate:anthropic_messages_to_internal(BodyA),
    {ok, RB} = erllama_server_translate:anthropic_messages_to_internal(BodyB),
    [#{hash := HashA}] = RA#erllama_request.cache_hints,
    [#{hash := HashB}] = RB#erllama_request.cache_hints,
    ?assertEqual(HashA, HashB).

%% usage.cache_read_input_tokens is populated when erllama reports an
%% exact KV-cache hit. The cache_creation_input_tokens counter is
%% credited on cold / partial misses. Coarse: we don't yet split
%% partial-hit prefix-tokens from the new tail, so partial is
%% reported as a full creation. Real users with an exact prefix hit
%% see the cache_read counter; cold first turns see cache_creation.
anthropic_usage_emits_cache_read_on_exact_hit(_Cfg) ->
    Stats = #{
        prompt_tokens => 128,
        completion_tokens => 16,
        cache_hit_kind => exact,
        finish_reason => stop
    },
    Resp = erllama_server_translate:internal_to_anthropic_messages_response(
        [text_block(<<"hi">>)], Stats, <<"m">>
    ),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(128, maps:get(<<"cache_read_input_tokens">>, Usage)),
    ?assertNot(maps:is_key(<<"cache_creation_input_tokens">>, Usage)).

anthropic_usage_emits_cache_creation_on_cold(_Cfg) ->
    Stats = #{
        prompt_tokens => 128,
        completion_tokens => 16,
        cache_hit_kind => cold,
        finish_reason => stop
    },
    Resp = erllama_server_translate:internal_to_anthropic_messages_response(
        [text_block(<<"hi">>)], Stats, <<"m">>
    ),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(128, maps:get(<<"cache_creation_input_tokens">>, Usage)),
    ?assertNot(maps:is_key(<<"cache_read_input_tokens">>, Usage)).

%% OpenAI surfaces the same info via prompt_tokens_details.cached_tokens.
openai_usage_emits_cached_tokens_on_exact_hit(_Cfg) ->
    Stats = #{
        prompt_tokens => 64,
        completion_tokens => 4,
        cache_hit_kind => exact,
        finish_reason => stop
    },
    Resp = erllama_server_translate:internal_to_openai_chat_response(
        <<"x">>, Stats, <<"m">>
    ),
    Usage = maps:get(<<"usage">>, Resp),
    Details = maps:get(<<"prompt_tokens_details">>, Usage),
    ?assertEqual(64, maps:get(<<"cached_tokens">>, Details)).

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
        [text_block(<<"hi">>)], Stats, <<"claude">>
    ),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, R)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, R)),
    [Block] = maps:get(<<"content">>, R),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"hi">>, maps:get(<<"text">>, Block)).

%% Non-streaming response now lets the handler choose the content
%% shape. A tool_use block must round-trip with id, name, and parsed
%% input, and the response carries stop_reason: "tool_use" when the
%% caller marks Stats accordingly.
anthropic_response_tool_use_block(_Cfg) ->
    Stats = #{prompt_tokens => 5, completion_tokens => 3, finish_reason => tool_call},
    ToolUse = #{
        <<"type">> => <<"tool_use">>,
        <<"id">> => <<"toolu_1">>,
        <<"name">> => <<"search">>,
        <<"input">> => #{<<"q">> => <<"hi">>}
    },
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        [ToolUse], Stats, <<"claude">>
    ),
    ?assertEqual(<<"tool_use">>, maps:get(<<"stop_reason">>, R)),
    [Block] = maps:get(<<"content">>, R),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"id">>, Block)),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Block)),
    ?assertEqual(#{<<"q">> => <<"hi">>}, maps:get(<<"input">>, Block)).

%% erllama 0.3.0 reports the matched caller-supplied stop string in
%% Stats.stop_sequence when generation halted on a stop_sequences match.
%% Anthropic clients expect stop_reason: "stop_sequence" + a non-null
%% stop_sequence field in that case.
anthropic_response_emits_stop_sequence_when_matched(_Cfg) ->
    Stats = #{
        prompt_tokens => 5,
        completion_tokens => 3,
        finish_reason => stop,
        stop_sequence => <<"END">>
    },
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        [text_block(<<"hi">>)], Stats, <<"claude">>
    ),
    ?assertEqual(<<"stop_sequence">>, maps:get(<<"stop_reason">>, R)),
    ?assertEqual(<<"END">>, maps:get(<<"stop_sequence">>, R)).

%% Without stop_sequence in Stats, natural-stop maps to end_turn and
%% the response.stop_sequence field is null.
anthropic_response_omits_stop_sequence_on_natural_stop(_Cfg) ->
    Stats = #{prompt_tokens => 5, completion_tokens => 3, finish_reason => stop},
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        [text_block(<<"hi">>)], Stats, <<"claude">>
    ),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, R)),
    ?assertEqual(null, maps:get(<<"stop_sequence">>, R)).

%% Streaming message_delta carries the same stop_sequence/stop_reason
%% pairing.
anthropic_event_message_delta_emits_stop_sequence(_Cfg) ->
    Stats = #{
        prompt_tokens => 5,
        completion_tokens => 3,
        finish_reason => stop,
        stop_sequence => <<"END">>
    },
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"\"stop_reason\":\"stop_sequence\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"stop_sequence\":\"END\"">>) =/= nomatch).

%% Non-streaming response can carry the signature on a thinking block.
%% Anthropic SDKs round-trip this on the next turn.
anthropic_response_thinking_block_with_signature(_Cfg) ->
    Stats = #{prompt_tokens => 5, completion_tokens => 3, finish_reason => stop},
    Blocks = [
        #{
            <<"type">> => <<"thinking">>,
            <<"thinking">> => <<"hmm">>,
            <<"signature">> => <<"sig-abc">>
        },
        text_block(<<"answer">>)
    ],
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        Blocks, Stats, <<"claude">>
    ),
    [B1, _] = maps:get(<<"content">>, R),
    ?assertEqual(<<"sig-abc">>, maps:get(<<"signature">>, B1)).

%% Non-streaming response can carry both a thinking and a text block.
anthropic_response_thinking_then_text_blocks(_Cfg) ->
    Stats = #{prompt_tokens => 5, completion_tokens => 3, finish_reason => stop},
    Blocks = [
        #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"hmm">>},
        text_block(<<"answer">>)
    ],
    R = erllama_server_translate:internal_to_anthropic_messages_response(
        Blocks, Stats, <<"claude">>
    ),
    [B1, B2] = maps:get(<<"content">>, R),
    ?assertEqual(<<"thinking">>, maps:get(<<"type">>, B1)),
    ?assertEqual(<<"hmm">>, maps:get(<<"thinking">>, B1)),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, B2)),
    ?assertEqual(<<"answer">>, maps:get(<<"text">>, B2)).

anthropic_event_message_start(_Cfg) ->
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_start, 42}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: message_start">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"id\":\"msg_1\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"input_tokens\":42">>) =/= nomatch).

anthropic_event_text_delta(_Cfg) ->
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {text_delta, <<"hello">>, 0}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"text\":\"hello\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"index\":0">>) =/= nomatch).

%% Anthropic SDK stream accumulators slot-fill `message.content[index]`,
%% so consecutive blocks must carry distinct indices. The emitter must
%% honour whatever index the handler supplies.
anthropic_event_content_block_index_threads_through(_Cfg) ->
    Start = iolist_to_binary(
        erllama_server_translate:internal_to_anthropic_event(
            {content_block_start_text, 3}, #{}, <<"msg_1">>, <<"claude">>
        )
    ),
    Delta = iolist_to_binary(
        erllama_server_translate:internal_to_anthropic_event(
            {text_delta, <<"t">>, 3}, #{}, <<"msg_1">>, <<"claude">>
        )
    ),
    Thinking = iolist_to_binary(
        erllama_server_translate:internal_to_anthropic_event(
            {thinking_delta, <<"r">>, 2}, #{}, <<"msg_1">>, <<"claude">>
        )
    ),
    Stop = iolist_to_binary(
        erllama_server_translate:internal_to_anthropic_event(
            {content_block_stop, 3}, #{}, <<"msg_1">>, <<"claude">>
        )
    ),
    ?assert(binary:match(Start, <<"\"index\":3">>) =/= nomatch),
    ?assert(binary:match(Delta, <<"\"index\":3">>) =/= nomatch),
    ?assert(binary:match(Thinking, <<"\"index\":2">>) =/= nomatch),
    ?assert(binary:match(Stop, <<"\"index\":3">>) =/= nomatch).

anthropic_event_message_delta(_Cfg) ->
    Stats = #{completion_tokens => 4, finish_reason => length},
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"event: message_delta">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"stop_reason\":\"max_tokens\"">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"output_tokens\":4">>) =/= nomatch).

%% Streaming clients (Claude Code, Anthropic SDK) read cache stats
%% from the final message_delta usage frame. Pre-fix this carried
%% only output_tokens so cache hits were invisible.
anthropic_event_message_delta_emits_cache_read_on_exact_hit(_Cfg) ->
    Stats = #{
        prompt_tokens => 128,
        completion_tokens => 4,
        cache_hit_kind => exact,
        finish_reason => stop
    },
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"\"cache_read_input_tokens\":128">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Bin, <<"\"cache_creation_input_tokens\"">>)).

anthropic_event_message_delta_emits_cache_creation_on_cold(_Cfg) ->
    Stats = #{
        prompt_tokens => 128,
        completion_tokens => 4,
        cache_hit_kind => cold,
        finish_reason => stop
    },
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"\"cache_creation_input_tokens\":128">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Bin, <<"\"cache_read_input_tokens\"">>)).

%% SDKs >=2024-08 read usage.cache_creation.{ephemeral_5m,1h}_input_tokens.
%% We can't distinguish per-block attribution from the engine, so the
%% coarse total falls into 5m by default; when any 1h cache_control
%% hint is present we attribute the total to 1h instead.
anthropic_event_message_delta_emits_cache_creation_nested_5m(_Cfg) ->
    Stats = #{
        prompt_tokens => 64,
        completion_tokens => 1,
        cache_hit_kind => cold,
        finish_reason => stop,
        cache_hints => [#{kind => system, hash => <<"h">>, ttl => <<"5m">>}]
    },
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"\"ephemeral_5m_input_tokens\":64">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"ephemeral_1h_input_tokens\":0">>) =/= nomatch).

anthropic_event_message_delta_emits_cache_creation_nested_1h(_Cfg) ->
    Stats = #{
        prompt_tokens => 64,
        completion_tokens => 1,
        cache_hit_kind => cold,
        finish_reason => stop,
        cache_hints => [#{kind => system, hash => <<"h">>, ttl => <<"1h">>}]
    },
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, Stats}, #{}, <<"msg_1">>, <<"claude">>
    ),
    Bin = iolist_to_binary(Iolist),
    ?assert(binary:match(Bin, <<"\"ephemeral_5m_input_tokens\":0">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"\"ephemeral_1h_input_tokens\":64">>) =/= nomatch).

%%====================================================================
%% Helpers
%%====================================================================

base_chat() ->
    #{
        <<"model">> => <<"x">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }.

text_block(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text}.
