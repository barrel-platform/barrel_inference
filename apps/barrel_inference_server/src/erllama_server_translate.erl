%%% Pure schema translation between OpenAI/Anthropic HTTP shapes and
%%% the server's internal `#erllama_request{}` record.
%%%
%%% Two directions:
%%%
%%%   *_to_internal/1   - request body decoded by `json:decode/1`
%%%                       (a map) -> `{ok, #erllama_request{}}` |
%%%                       `{error, Reason}`.
%%%   internal_to_*/2   - `#erllama_request{}` plus the per-response
%%%                       state needed by the handler ->
%%%                       JSON-encodable map (or list, for SSE).
%%%
%%% This module is pure Erlang. No erllama, no Cowboy, no I/O. Tests
%%% drive it directly with map literals.

-module(erllama_server_translate).

-include("erllama_server.hrl").

-type anthropic_event_kind() ::
    {message_start, non_neg_integer()}
    | {content_block_start_text, non_neg_integer()}
    | {text_delta, binary(), non_neg_integer()}
    | {thinking_delta, binary(), non_neg_integer()}
    | {content_block_stop, non_neg_integer()}
    | {message_delta, map()}
    | message_stop.

-export_type([anthropic_event_kind/0]).

-export([
    %% request: in
    openai_chat_to_internal/1,
    openai_completion_to_internal/1,
    openai_responses_to_internal/1,
    openai_embeddings_to_internal/1,
    anthropic_messages_to_internal/1,
    ollama_generate_to_internal/1,
    ollama_chat_to_internal/1,
    ollama_embed_to_internal/1,
    ollama_embeddings_legacy_to_internal/1,
    %% response: out
    internal_to_openai_chat_response/3,
    internal_to_openai_chat_chunk/3,
    internal_to_openai_reasoning_chunk/3,
    internal_to_openai_chat_final/3,
    internal_to_openai_usage_chunk/3,
    internal_to_openai_completion_response/3,
    internal_to_openai_embedding_response/3,
    internal_to_anthropic_messages_response/3,
    internal_to_anthropic_event/4,
    internal_to_ollama_generate_chunk/3,
    internal_to_ollama_generate_final/4,
    internal_to_ollama_generate_response/4,
    internal_to_ollama_chat_chunk/3,
    internal_to_ollama_chat_final/4,
    internal_to_ollama_chat_response/4,
    ollama_preload_response/4,
    internal_to_ollama_embed_response/4,
    internal_to_ollama_embeddings_legacy_response/3,
    %% openai responses
    internal_to_responses_object/5,
    internal_to_responses_completed/5,
    internal_to_responses_partial/2,
    internal_to_responses_message_added/2,
    internal_to_responses_content_added/2,
    internal_to_responses_text_delta/3,
    internal_to_responses_text_done/3,
    internal_to_responses_content_done/3,
    internal_to_responses_message_done/3,
    internal_to_responses_function_call_added/4,
    internal_to_responses_function_args_delta/2,
    internal_to_responses_function_args_done/2,
    internal_to_responses_function_call_done/4,
    internal_to_responses_failed/4,
    responses_event/2,
    %% helpers
    make_id/1,
    parse_keep_alive/1,
    parse_response_format_openai/1,
    parse_response_format_ollama/1,
    parse_anthropic_betas_body/1
]).

%%====================================================================
%% Request to internal
%%====================================================================

-spec openai_chat_to_internal(map()) ->
    {ok, #erllama_request{}} | {error, term()}.
openai_chat_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        MessagesIn = required_list(Body, <<"messages">>),
        check_messages_cap(MessagesIn),
        {System, Messages} = split_system(MessagesIn),
        Tools = parse_openai_tools(Body),
        check_tools_cap(Tools),
        ToolChoice = parse_openai_tool_choice(Body),
        RF = parse_response_format_openai(maps:get(<<"response_format">>, Body, undefined)),
        Base = base_request(Body, openai),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = Messages,
            prompt = undefined,
            system = System,
            tools = Tools,
            tool_choice = ToolChoice,
            response_format = RF
        }}
    catch
        throw:{error, _} = E -> E
    end;
openai_chat_to_internal(_) ->
    {error, invalid_json}.

%% OpenAI /v1/responses request body. `input` is either a string or a
%% list of input items. `instructions` is prepended to any system
%% message. Built-in tools (`web_search`, `file_search`,
%% `computer_use_preview`) raise `{error, {builtin_tool_not_supported, _}}`
%% so the handler can answer 501. `max_output_tokens` is the Responses
%% naming for the chat-completions `max_tokens` cap.
-spec openai_responses_to_internal(map()) ->
    {ok, #erllama_request{}} | {error, term()}.
openai_responses_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        InputRaw =
            case maps:get(<<"input">>, Body, undefined) of
                undefined -> throw({error, {missing_field, <<"input">>}});
                V -> V
            end,
        {SystemFromInput, MessagesIn} = parse_responses_input(InputRaw),
        check_messages_cap(MessagesIn),
        Instructions = parse_responses_instructions(Body),
        System = merge_instructions_system(Instructions, SystemFromInput),
        Tools = parse_responses_tools(Body),
        check_tools_cap(Tools),
        ToolChoice = parse_openai_tool_choice(Body),
        RF = parse_response_format_openai(
            maps:get(<<"response_format">>, Body, undefined)
        ),
        maybe_warn_previous_response_id(Body),
        Base = base_request(Body, openai),
        Base1 = Base#erllama_request{
            max_tokens = responses_max_tokens(Body, Base#erllama_request.max_tokens),
            user_id = parse_metadata_user_id(Body)
        },
        {ok, Base1#erllama_request{
            model_id = Model,
            messages = MessagesIn,
            prompt = undefined,
            system = System,
            tools = Tools,
            tool_choice = ToolChoice,
            response_format = RF
        }}
    catch
        throw:{error, _} = E -> E
    end;
openai_responses_to_internal(_) ->
    {error, invalid_json}.

%% Parse the Responses `input` field. A bare string maps to a single
%% user message. A list normalises each item to the internal message
%% shape. We tolerate a "message"-typed wrapper (the Responses API
%% sometimes wraps role/content in `{"type":"message", ...}`) and a
%% plain `{"role":..., "content":...}` form. The split returns any
%% `system`-role messages separately so a top-level `instructions`
%% field can be prepended.
parse_responses_input(B) when is_binary(B) ->
    {undefined, [#{role => <<"user">>, content => B}]};
parse_responses_input(L) when is_list(L) ->
    Normalised = [normalise_responses_input_item(I) || I <- L],
    {Sys, Rest} = split_responses_system(Normalised),
    {Sys, Rest};
parse_responses_input(_) ->
    throw({error, {invalid_field, <<"input">>}}).

normalise_responses_input_item(B) when is_binary(B) ->
    #{role => <<"user">>, content => B};
normalise_responses_input_item(#{<<"type">> := Type} = Item) when is_binary(Type) ->
    %% A handful of `type` values are valid wrappers: "message",
    %% "input_text" (used for vision-shaped content blocks). The
    %% built-in server tool items show up here as e.g. "web_search",
    %% "file_search", "computer_use_preview" and must be rejected
    %% with 501.
    case Type of
        <<"message">> ->
            normalise_responses_message(Item);
        <<"input_text">> ->
            #{
                role => <<"user">>,
                content => content_value(maps:get(<<"text">>, Item, <<>>))
            };
        <<"function_call">> ->
            %% Replayed assistant tool_call from a prior turn. Treat as
            %% an assistant message with a stable marker so the inference
            %% context preserves the call.
            Name = maps:get(<<"name">>, Item, <<"unknown">>),
            Id = maps:get(<<"id">>, Item, <<>>),
            Marker = <<"[tool_call name=", Name/binary, " id=", Id/binary, "]">>,
            #{role => <<"assistant">>, content => Marker};
        <<"function_call_output">> ->
            CallId = maps:get(<<"call_id">>, Item, <<>>),
            Output = maps:get(<<"output">>, Item, <<>>),
            Body = content_value(Output),
            #{
                role => <<"tool">>,
                content => <<"[tool_result id=", CallId/binary, "]: ", Body/binary>>
            };
        Builtin when
            Builtin =:= <<"web_search">>;
            Builtin =:= <<"file_search">>;
            Builtin =:= <<"computer_use_preview">>;
            Builtin =:= <<"code_interpreter">>
        ->
            throw({error, {builtin_tool_not_supported, Builtin}});
        Other ->
            throw({error, {unsupported_input_part, Other}})
    end;
normalise_responses_input_item(#{<<"role">> := _} = Msg) ->
    normalise_responses_message(Msg);
normalise_responses_input_item(_) ->
    throw({error, {invalid_field, <<"input">>}}).

normalise_responses_message(#{<<"role">> := Role} = M) ->
    #{role => Role, content => content_value(maps:get(<<"content">>, M, <<>>))};
normalise_responses_message(_) ->
    throw({error, {invalid_field, <<"input">>}}).

split_responses_system(Items) ->
    {SysParts, Rest} =
        lists:partition(
            fun
                (#{role := <<"system">>}) -> true;
                (_) -> false
            end,
            Items
        ),
    System =
        case SysParts of
            [] -> undefined;
            _ -> binary_join([sys_text(M) || M <- SysParts], <<"\n\n">>)
        end,
    {System, Rest}.

sys_text(#{content := B}) when is_binary(B) -> B.

parse_responses_instructions(Body) ->
    case maps:get(<<"instructions">>, Body, undefined) of
        undefined -> undefined;
        null -> undefined;
        B when is_binary(B), B =/= <<>> -> B;
        _ -> undefined
    end.

%% `instructions` is prepended to the system message; when the input
%% has no system part the instructions become the system text.
merge_instructions_system(undefined, System) ->
    System;
merge_instructions_system(Instructions, undefined) ->
    Instructions;
merge_instructions_system(Instructions, System) ->
    <<Instructions/binary, "\n\n", System/binary>>.

%% Responses-shape tools. The Responses API accepts the same function
%% shape as Chat Completions (under `{"type":"function", "function":
%% {...}}`) plus built-in server tools. We accept the function form
%% and reject anything else with a 501-mapped error so the handler can
%% answer with the right HTTP status.
parse_responses_tools(Body) ->
    case maps:get(<<"tools">>, Body, undefined) of
        undefined ->
            undefined;
        Tools when is_list(Tools) ->
            [parse_responses_tool(T) || T <- Tools];
        _ ->
            undefined
    end.

parse_responses_tool(#{<<"type">> := <<"function">>, <<"function">> := F}) when
    is_map(F)
->
    #{
        name => maps:get(<<"name">>, F),
        description => maps:get(<<"description">>, F, <<>>),
        schema => maps:get(<<"parameters">>, F, #{})
    };
parse_responses_tool(#{<<"type">> := <<"function">>} = F) ->
    %% Some Responses-shape callers flatten function fields onto the
    %% tool object directly (no nested `function` key).
    #{
        name => maps:get(<<"name">>, F),
        description => maps:get(<<"description">>, F, <<>>),
        schema => maps:get(<<"parameters">>, F, #{})
    };
parse_responses_tool(#{<<"type">> := Type}) when is_binary(Type) ->
    throw({error, {builtin_tool_not_supported, Type}});
parse_responses_tool(_) ->
    throw({error, {invalid_field, <<"tools">>}}).

%% Responses uses `max_output_tokens` instead of `max_tokens`. When
%% both are present, `max_output_tokens` wins.
responses_max_tokens(Body, Default) ->
    case maps:get(<<"max_output_tokens">>, Body, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end.

%% `previous_response_id` deferred to a follow-up. Surface a notice so
%% operators see early adopters who hit the future-feature wall.
maybe_warn_previous_response_id(Body) ->
    case maps:get(<<"previous_response_id">>, Body, undefined) of
        undefined ->
            ok;
        null ->
            ok;
        _Id ->
            logger:notice(#{
                event => responses_previous_response_id_ignored,
                message =>
                    <<"previous_response_id is not yet supported; the client should replay input">>
            }),
            ok
    end.

-spec openai_completion_to_internal(map()) ->
    {ok, #erllama_request{}} | {error, term()}.
openai_completion_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        Prompt = required_binary(Body, <<"prompt">>),
        RF = parse_response_format_openai(maps:get(<<"response_format">>, Body, undefined)),
        Base = base_request(Body, openai),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = [],
            prompt = Prompt,
            system = undefined,
            tools = undefined,
            tool_choice = none,
            response_format = RF
        }}
    catch
        throw:{error, _} = E -> E
    end;
openai_completion_to_internal(_) ->
    {error, invalid_json}.

-spec openai_embeddings_to_internal(map()) ->
    {ok, #{model := binary(), inputs := [binary()]}} | {error, term()}.
openai_embeddings_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        Inputs =
            case maps:get(<<"input">>, Body, undefined) of
                undefined ->
                    throw({error, missing_input});
                I when is_binary(I) ->
                    [I];
                I when is_list(I) ->
                    lists:map(
                        fun
                            (B) when is_binary(B) -> B;
                            (_) -> throw({error, unsupported_input_type})
                        end,
                        I
                    );
                _ ->
                    throw({error, unsupported_input_type})
            end,
        {ok, #{model => Model, inputs => Inputs}}
    catch
        throw:{error, _} = E -> E
    end;
openai_embeddings_to_internal(_) ->
    {error, invalid_json}.

-spec anthropic_messages_to_internal(map()) ->
    {ok, #erllama_request{}} | {error, term()}.
anthropic_messages_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        MessagesIn = required_list(Body, <<"messages">>),
        check_messages_cap(MessagesIn),
        SystemRaw = maps:get(<<"system">>, Body, undefined),
        System = parse_anthropic_system(SystemRaw),
        Messages = [normalise_message(M) || M <- MessagesIn],
        Tools = parse_anthropic_tools(Body),
        check_tools_cap(Tools),
        ToolChoice = parse_anthropic_tool_choice(Body),
        Thinking = parse_anthropic_thinking(Body),
        CacheHints = collect_cache_hints(SystemRaw, MessagesIn, Body),
        RF = parse_anthropic_output_config(Body),
        Base = base_request(Body, anthropic),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = Messages,
            prompt = undefined,
            system = System,
            tools = Tools,
            tool_choice = ToolChoice,
            thinking = Thinking,
            cache_hints = CacheHints,
            response_format = RF,
            %% Anthropic uses `stop_sequences` (plural); base_request
            %% only reads `stop` (OpenAI/Ollama naming). Override here
            %% so Anthropic clients don't lose their stop tokens.
            stop = parse_stop_sequences(Body),
            user_id = parse_metadata_user_id(Body),
            thinking_display = parse_anthropic_thinking_display(Body),
            thinking_budget = parse_anthropic_thinking_budget(Body)
        }}
    catch
        throw:{error, _} = E -> E
    end;
anthropic_messages_to_internal(_) ->
    {error, invalid_json}.

%%====================================================================
%% Internal to response
%%====================================================================

%% Streaming OpenAI chat chunk for a single text token. Returns an
%% iolist (the JSON portion of `data: <json>\n\n`).
-spec internal_to_openai_chat_chunk(binary(), binary(), binary()) -> iodata().
internal_to_openai_chat_chunk(Token, ReqId, Model) ->
    Created = unix_seconds(),
    Chunk = #{
        <<"id">> => ReqId,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{<<"content">> => Token},
                <<"finish_reason">> => null
            }
        ]
    },
    json:encode(Chunk).

%% Streaming OpenAI reasoning chunk. Same shape but with
%% `delta.reasoning_content` instead of `delta.content` (the de-facto
%% extension shipped by DeepSeek that most OpenAI-compat clients
%% accept).
-spec internal_to_openai_reasoning_chunk(binary(), binary(), binary()) -> iodata().
internal_to_openai_reasoning_chunk(Token, ReqId, Model) ->
    Created = unix_seconds(),
    Chunk = #{
        <<"id">> => ReqId,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{<<"reasoning_content">> => Token},
                <<"finish_reason">> => null
            }
        ]
    },
    json:encode(Chunk).

%% Final SSE frame for an OpenAI chat completion: an empty delta
%% with finish_reason set and `usage: null`. Per the OpenAI wire
%% contract every chunk (including this one) carries `usage: null`;
%% the real usage rides a separate trailing chunk emitted only when
%% the client set `stream_options.include_usage` (see
%% `internal_to_openai_usage_chunk/3'). The caller appends the
%% optional usage chunk and `[DONE]` after.
-spec internal_to_openai_chat_final(map(), binary(), binary()) -> iodata().
internal_to_openai_chat_final(Stats, ReqId, Model) ->
    Final = #{
        <<"id">> => ReqId,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => unix_seconds(),
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{},
                <<"finish_reason">> => finish_reason_atom(Stats)
            }
        ],
        <<"usage">> => null
    },
    json:encode(Final).

%% Trailing usage-only chunk for `stream_options.include_usage`.
%% Empty `choices`, populated `usage`. Emitted just before
%% `[DONE]', and only when the client opted in.
-spec internal_to_openai_usage_chunk(map(), binary(), binary()) -> iodata().
internal_to_openai_usage_chunk(Stats, ReqId, Model) ->
    Chunk = #{
        <<"id">> => ReqId,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => unix_seconds(),
        <<"model">> => Model,
        <<"choices">> => [],
        <<"usage">> => usage_map(Stats)
    },
    json:encode(Chunk).

%% Non-streaming OpenAI chat response.
-spec internal_to_openai_chat_response(binary(), map(), binary()) -> map().
internal_to_openai_chat_response(Text, Stats, Model) ->
    #{
        <<"id">> => make_id(<<"chatcmpl-">>),
        <<"object">> => <<"chat.completion">>,
        <<"created">> => unix_seconds(),
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"message">> => #{
                    <<"role">> => <<"assistant">>,
                    <<"content">> => Text
                },
                <<"finish_reason">> => finish_reason_atom(Stats)
            }
        ],
        <<"usage">> => usage_map(Stats)
    }.

%% Non-streaming OpenAI legacy completions response.
-spec internal_to_openai_completion_response(binary(), map(), binary()) -> map().
internal_to_openai_completion_response(Text, Stats, Model) ->
    #{
        <<"id">> => make_id(<<"cmpl-">>),
        <<"object">> => <<"text_completion">>,
        <<"created">> => unix_seconds(),
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"text">> => Text,
                <<"logprobs">> => null,
                <<"finish_reason">> => finish_reason_atom(Stats)
            }
        ],
        <<"usage">> => usage_map(Stats)
    }.

%%====================================================================
%% OpenAI Responses (/v1/responses)
%%
%% Non-streaming returns one JSON envelope. Streaming emits a series of
%% named SSE events; the handler owns the index bookkeeping (one
%% `output_index` per top-level output item, one `content_index` per
%% content part inside a message item).
%%====================================================================

%% Non-streaming /v1/responses response object. `Items` is the list of
%% complete output items already shaped by the handler (one message
%% item with `output_text` parts and zero or more function_call items).
-spec internal_to_responses_object(
    binary(), binary(), [map()], map(), binary()
) -> map().
internal_to_responses_object(ResponseId, _MsgId, Items, Stats, Model) when
    is_list(Items)
->
    #{
        <<"id">> => ResponseId,
        <<"object">> => <<"response">>,
        <<"created_at">> => unix_seconds(),
        <<"status">> => <<"completed">>,
        <<"model">> => Model,
        <<"output">> => Items,
        <<"usage">> => usage_map_responses(Stats),
        <<"metadata">> => #{}
    }.

%% Streaming counterpart: payload for the `response.completed` event.
-spec internal_to_responses_completed(
    binary(), binary(), [map()], map(), binary()
) -> map().
internal_to_responses_completed(ResponseId, MsgId, Items, Stats, Model) ->
    #{
        <<"response">> =>
            internal_to_responses_object(ResponseId, MsgId, Items, Stats, Model)
    }.

%% Streaming `response.created` payload. Partial response object with
%% `status: in_progress` and an empty output array. The streaming
%% handler emits this immediately after `stream_reply/3`.
-spec internal_to_responses_partial(binary(), binary()) -> map().
internal_to_responses_partial(ResponseId, Model) ->
    #{
        <<"response">> => #{
            <<"id">> => ResponseId,
            <<"object">> => <<"response">>,
            <<"created_at">> => unix_seconds(),
            <<"status">> => <<"in_progress">>,
            <<"model">> => Model,
            <<"output">> => [],
            <<"metadata">> => #{}
        }
    }.

%% `response.output_item.added` for the assistant message item. The
%% item is partial: status=in_progress, empty content array; content
%% parts are streamed in as `response.content_part.added`.
-spec internal_to_responses_message_added(non_neg_integer(), binary()) -> map().
internal_to_responses_message_added(OutIndex, MsgId) ->
    #{
        <<"output_index">> => OutIndex,
        <<"item">> => #{
            <<"type">> => <<"message">>,
            <<"id">> => MsgId,
            <<"role">> => <<"assistant">>,
            <<"status">> => <<"in_progress">>,
            <<"content">> => []
        }
    }.

%% `response.content_part.added` for an output_text part.
-spec internal_to_responses_content_added(
    non_neg_integer(), non_neg_integer()
) -> map().
internal_to_responses_content_added(OutIndex, ContentIndex) ->
    #{
        <<"output_index">> => OutIndex,
        <<"content_index">> => ContentIndex,
        <<"part">> => #{<<"type">> => <<"output_text">>, <<"text">> => <<>>}
    }.

%% `response.output_text.delta` per token chunk.
-spec internal_to_responses_text_delta(
    non_neg_integer(), non_neg_integer(), binary()
) -> map().
internal_to_responses_text_delta(OutIndex, ContentIndex, Delta) ->
    #{
        <<"output_index">> => OutIndex,
        <<"content_index">> => ContentIndex,
        <<"delta">> => Delta
    }.

%% `response.output_text.done` carrying the full text emitted into the
%% part.
-spec internal_to_responses_text_done(
    non_neg_integer(), non_neg_integer(), binary()
) -> map().
internal_to_responses_text_done(OutIndex, ContentIndex, Text) ->
    #{
        <<"output_index">> => OutIndex,
        <<"content_index">> => ContentIndex,
        <<"text">> => Text
    }.

%% `response.content_part.done` closing the part with its full text.
-spec internal_to_responses_content_done(
    non_neg_integer(), non_neg_integer(), binary()
) -> map().
internal_to_responses_content_done(OutIndex, ContentIndex, Text) ->
    #{
        <<"output_index">> => OutIndex,
        <<"content_index">> => ContentIndex,
        <<"part">> => #{<<"type">> => <<"output_text">>, <<"text">> => Text}
    }.

%% `response.output_item.done` for the assistant message item, with the
%% complete content array (one or more output_text parts).
-spec internal_to_responses_message_done(
    non_neg_integer(), binary(), binary()
) -> map().
internal_to_responses_message_done(OutIndex, MsgId, Text) ->
    #{
        <<"output_index">> => OutIndex,
        <<"item">> => #{
            <<"type">> => <<"message">>,
            <<"id">> => MsgId,
            <<"role">> => <<"assistant">>,
            <<"status">> => <<"completed">>,
            <<"content">> => [
                #{<<"type">> => <<"output_text">>, <<"text">> => Text}
            ]
        }
    }.

%% `response.output_item.added` for a function_call item. Partial:
%% name is known, arguments are empty until the deltas finish.
-spec internal_to_responses_function_call_added(
    non_neg_integer(), binary(), binary(), binary()
) -> map().
internal_to_responses_function_call_added(OutIndex, FcId, CallId, Name) ->
    #{
        <<"output_index">> => OutIndex,
        <<"item">> => #{
            <<"type">> => <<"function_call">>,
            <<"id">> => FcId,
            <<"call_id">> => CallId,
            <<"name">> => Name,
            <<"arguments">> => <<>>,
            <<"status">> => <<"in_progress">>
        }
    }.

%% `response.function_call_arguments.delta` carrying a JSON chunk.
-spec internal_to_responses_function_args_delta(
    non_neg_integer(), binary()
) -> map().
internal_to_responses_function_args_delta(OutIndex, Delta) ->
    #{<<"output_index">> => OutIndex, <<"delta">> => Delta}.

%% `response.function_call_arguments.done` with the full arguments
%% JSON string.
-spec internal_to_responses_function_args_done(
    non_neg_integer(), binary()
) -> map().
internal_to_responses_function_args_done(OutIndex, Arguments) ->
    #{<<"output_index">> => OutIndex, <<"arguments">> => Arguments}.

%% `response.output_item.done` for a function_call item.
-spec internal_to_responses_function_call_done(
    non_neg_integer(), binary(), binary(), binary()
) -> map().
internal_to_responses_function_call_done(OutIndex, FcId, CallId, Name) ->
    %% Arguments are passed by the caller as a JSON string already
    %% built from the captured tool_use input. We fold them into the
    %% Name arg slot for simplicity.
    #{
        <<"output_index">> => OutIndex,
        <<"item">> => #{
            <<"type">> => <<"function_call">>,
            <<"id">> => FcId,
            <<"call_id">> => CallId,
            <<"name">> => Name,
            <<"status">> => <<"completed">>
        }
    }.

%% `response.failed` payload: a response object stamped with
%% status=failed and an error envelope. Used by the streaming handler
%% on post-stream errors.
-spec internal_to_responses_failed(
    binary(), binary(), binary(), binary()
) -> map().
internal_to_responses_failed(ResponseId, Model, Code, Message) ->
    #{
        <<"response">> => #{
            <<"id">> => ResponseId,
            <<"object">> => <<"response">>,
            <<"created_at">> => unix_seconds(),
            <<"status">> => <<"failed">>,
            <<"model">> => Model,
            <<"output">> => [],
            <<"error">> => #{<<"code">> => Code, <<"message">> => Message}
        }
    }.

%% SSE renderer for /v1/responses events. Same wire shape as sse/2.
-spec responses_event(binary(), map()) -> iodata().
responses_event(EventName, Payload) ->
    sse(EventName, Payload).

%% Responses uses input_tokens / output_tokens / total_tokens (not the
%% chat-completions prompt_tokens / completion_tokens).
usage_map_responses(Stats) ->
    PromptTokens = maps:get(prompt_tokens, Stats, 0),
    CompletionTokens = maps:get(completion_tokens, Stats, 0),
    #{
        <<"input_tokens">> => PromptTokens,
        <<"output_tokens">> => CompletionTokens,
        <<"total_tokens">> => PromptTokens + CompletionTokens
    }.

%% OpenAI embeddings response. `Vectors` is a list of float-lists in
%% the order matching the request inputs. `PromptTokens` is the total
%% token count summed across inputs.
-spec internal_to_openai_embedding_response(
    [[float()]], non_neg_integer(), binary()
) -> map().
internal_to_openai_embedding_response(Vectors, PromptTokens, Model) ->
    Data = lists:map(
        fun({I, V}) ->
            #{
                <<"object">> => <<"embedding">>,
                <<"index">> => I,
                <<"embedding">> => V
            }
        end,
        index_zero(Vectors)
    ),
    #{
        <<"object">> => <<"list">>,
        <<"data">> => Data,
        <<"model">> => Model,
        <<"usage">> => #{
            <<"prompt_tokens">> => PromptTokens,
            <<"total_tokens">> => PromptTokens
        }
    }.

%% Non-streaming Anthropic /v1/messages response. The caller assembles
%% the Content list because only the handler knows whether to emit a
%% text block, a tool_use block, or a thinking + text composite.
-spec internal_to_anthropic_messages_response([map()], map(), binary()) -> map().
internal_to_anthropic_messages_response(Content, Stats, Model) when is_list(Content) ->
    #{
        <<"id">> => make_id(<<"msg_">>),
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => Model,
        <<"content">> => Content,
        <<"stop_reason">> => anthropic_stop_reason(Stats),
        <<"stop_sequence">> => anthropic_stop_sequence(Stats),
        <<"usage">> => anthropic_usage_map(Stats)
    }.

%% Anthropic's `usage` schema carries cache_creation_input_tokens and
%% cache_read_input_tokens whenever prompt caching is involved. Emit
%% them based on erllama's `cache_hit_kind`; the same coarse mapping
%% as the OpenAI `cached_tokens` field.
anthropic_usage_map(Stats) ->
    %% `service_tier` is part of the response usage shape; we have no
    %% tier scheduling, so always answer "standard". Future work could
    %% expose batch/priority if the engine grows them.
    Base = #{
        <<"input_tokens">> => maps:get(prompt_tokens, Stats, 0),
        <<"output_tokens">> => maps:get(completion_tokens, Stats, 0),
        <<"service_tier">> => <<"standard">>
    },
    Read = cached_tokens(Stats),
    Create = cache_creation_tokens(Stats),
    Maybe1 =
        case Read of
            0 -> Base;
            _ -> Base#{<<"cache_read_input_tokens">> => Read}
        end,
    case Create of
        0 ->
            Maybe1;
        _ ->
            Nested = cache_creation_ttl_split(Create, Stats),
            Maybe1#{
                <<"cache_creation_input_tokens">> => Create,
                <<"cache_creation">> => Nested
            }
    end.

%% SDKs newer than 2024-08 read the nested
%% `usage.cache_creation.ephemeral_{5m,1h}_input_tokens` form. We can't
%% distinguish per-block hit attribution from the engine yet; we use
%% the request-side cache_hints (carried on Stats as `cache_hints`) to
%% decide which TTL bucket the coarse total falls into. If both 5m
%% and 1h hints are present, prefer 1h (worst case for SDK display).
cache_creation_ttl_split(Total, Stats) ->
    Hints = maps:get(cache_hints, Stats, []),
    Has1h = lists:any(fun(#{ttl := T}) -> T =:= <<"1h">> end, Hints),
    case Has1h of
        true ->
            #{
                <<"ephemeral_5m_input_tokens">> => 0,
                <<"ephemeral_1h_input_tokens">> => Total
            };
        false ->
            #{
                <<"ephemeral_5m_input_tokens">> => Total,
                <<"ephemeral_1h_input_tokens">> => 0
            }
    end.

%% Anthropic SSE event encoder. Returns iolist containing
%% `event: <name>\ndata: <json>\n\n`.
-spec internal_to_anthropic_event(
    anthropic_event_kind(), map(), binary(), binary()
) -> iodata().
internal_to_anthropic_event({message_start, PromptTokens}, _Acc, ReqId, Model) when
    is_integer(PromptTokens)
->
    Payload = #{
        <<"type">> => <<"message_start">>,
        <<"message">> => #{
            <<"id">> => ReqId,
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"model">> => Model,
            <<"content">> => [],
            <<"stop_reason">> => null,
            <<"stop_sequence">> => null,
            <<"usage">> => #{
                <<"input_tokens">> => PromptTokens,
                <<"output_tokens">> => 0
            }
        }
    },
    sse(<<"message_start">>, Payload);
internal_to_anthropic_event({content_block_start_text, Index}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_start">>,
        #{
            <<"type">> => <<"content_block_start">>,
            <<"index">> => Index,
            <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
        }
    );
internal_to_anthropic_event({text_delta, Bin, Index}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_delta">>,
        #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => Index,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Bin}
        }
    );
internal_to_anthropic_event({thinking_delta, Bin, Index}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_delta">>,
        #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => Index,
            <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => Bin}
        }
    );
internal_to_anthropic_event({content_block_stop, Index}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_stop">>,
        #{<<"type">> => <<"content_block_stop">>, <<"index">> => Index}
    );
internal_to_anthropic_event({message_delta, Stats}, _Acc, _ReqId, _Model) ->
    sse(
        <<"message_delta">>,
        #{
            <<"type">> => <<"message_delta">>,
            <<"delta">> => #{
                <<"stop_reason">> => anthropic_stop_reason(Stats),
                <<"stop_sequence">> => anthropic_stop_sequence(Stats)
            },
            %% Final usage frame: carry cache_creation_input_tokens
            %% / cache_read_input_tokens so streaming Anthropic
            %% clients (Claude Code) see the same prompt-caching
            %% counters as non-streaming.
            <<"usage">> => anthropic_usage_map(Stats)
        }
    );
internal_to_anthropic_event(message_stop, _Acc, _ReqId, _Model) ->
    sse(<<"message_stop">>, #{<<"type">> => <<"message_stop">>}).

%%====================================================================
%% Internal helpers
%%====================================================================

base_request(Body, Api) ->
    #erllama_request{
        model_id = <<>>,
        messages = [],
        prompt = undefined,
        system = undefined,
        tools = undefined,
        tool_choice = auto,
        grammar = undefined,
        max_tokens = parse_int(Body, <<"max_tokens">>, 1024),
        temperature = parse_float(Body, <<"temperature">>, 1.0),
        top_p = parse_float(Body, <<"top_p">>, 1.0),
        top_k = parse_int(Body, <<"top_k">>, 40),
        min_p = parse_float(Body, <<"min_p">>, 0.0),
        seed = parse_optional_int(Body, <<"seed">>),
        stop = parse_stop(Body),
        stream = parse_bool(Body, <<"stream">>, false),
        thinking = disabled,
        api = Api,
        request_id = make_id(prefix_for(Api)),
        include_usage = parse_include_usage(Body),
        parallel_tool_calls = parse_bool(Body, <<"parallel_tool_calls">>, true)
    }.

%% OpenAI `stream_options: {"include_usage": true}`. Absent or
%% malformed -> false. Only meaningful on the streaming path.
parse_include_usage(Body) ->
    case maps:get(<<"stream_options">>, Body, undefined) of
        Opts when is_map(Opts) ->
            parse_bool(Opts, <<"include_usage">>, false);
        _ ->
            false
    end.

prefix_for(openai) -> <<"chatcmpl-">>;
prefix_for(anthropic) -> <<"msg_">>;
prefix_for(ollama) -> <<"ollama-">>.

%% =============================================================================
%% Ollama: request -> #erllama_request{}
%% =============================================================================

%% Translate `POST /api/generate` body into the internal request.
%% Empty `prompt` -> `is_preload = true`.
-spec ollama_generate_to_internal(map()) -> {ok, #erllama_request{}} | {error, term()}.
ollama_generate_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        PromptRaw = maps:get(<<"prompt">>, Body, <<>>),
        Prompt = ensure_binary_or_undef(PromptRaw),
        System = maps:get(<<"system">>, Body, undefined),
        Base = base_request_ollama(Body),
        IsPreload =
            case Prompt of
                undefined -> true;
                <<>> -> true;
                _ -> false
            end,
        EffectivePrompt =
            case IsPreload of
                true -> undefined;
                false -> Prompt
            end,
        RF = parse_response_format_ollama(maps:get(<<"format">>, Body, undefined)),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = [],
            prompt = EffectivePrompt,
            system = System,
            tools = undefined,
            tool_choice = none,
            is_preload = IsPreload,
            response_format = RF
        }}
    catch
        throw:{error, _} = E -> E
    end;
ollama_generate_to_internal(_) ->
    {error, invalid_json}.

%% Translate `POST /api/chat` body. Empty `messages` -> preload.
-spec ollama_chat_to_internal(map()) -> {ok, #erllama_request{}} | {error, term()}.
ollama_chat_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        MessagesIn =
            case maps:get(<<"messages">>, Body, []) of
                L when is_list(L) -> L;
                _ -> throw({error, invalid_messages})
            end,
        IsPreload = (MessagesIn =:= []),
        case IsPreload of
            true -> ok;
            false -> check_messages_cap(MessagesIn)
        end,
        {System, Messages} = split_system(MessagesIn),
        Base = base_request_ollama(Body),
        RF = parse_response_format_ollama(maps:get(<<"format">>, Body, undefined)),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = Messages,
            prompt = undefined,
            system = System,
            tools = undefined,
            tool_choice = none,
            is_preload = IsPreload,
            response_format = RF
        }}
    catch
        throw:{error, _} = E -> E
    end;
ollama_chat_to_internal(_) ->
    {error, invalid_json}.

base_request_ollama(Body) ->
    Options = maps:get(<<"options">>, Body, #{}),
    KeepAlive = parse_keep_alive(maps:get(<<"keep_alive">>, Body, undefined)),
    #erllama_request{
        model_id = <<>>,
        messages = [],
        prompt = undefined,
        system = undefined,
        tools = undefined,
        tool_choice = none,
        grammar = undefined,
        max_tokens = parse_int(Options, <<"num_predict">>, 1024),
        temperature = parse_float(Options, <<"temperature">>, 1.0),
        top_p = parse_float(Options, <<"top_p">>, 1.0),
        top_k = parse_int(Options, <<"top_k">>, 40),
        min_p = parse_float(Options, <<"min_p">>, 0.0),
        seed = parse_optional_int(Options, <<"seed">>),
        stop = parse_stop(Options),
        stream = parse_bool(Body, <<"stream">>, true),
        thinking = disabled,
        api = openai,
        request_id = make_id(prefix_for(ollama)),
        keep_alive_ms = KeepAlive
    }.

ensure_binary_or_undef(undefined) -> undefined;
ensure_binary_or_undef(B) when is_binary(B) -> B;
ensure_binary_or_undef(_) -> undefined.

%% =============================================================================
%% Ollama: embeddings (new + legacy shape)
%% =============================================================================

%% New shape (`POST /api/embed`):
%%   {"model": "...", "input": "text" | ["a","b"], "truncate": bool,
%%    "keep_alive": "5m", "options": {...}}
-spec ollama_embed_to_internal(map()) ->
    {ok, #{model := binary(), inputs := [binary()], keep_alive_ms := term()}} | {error, term()}.
ollama_embed_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        Inputs =
            case maps:get(<<"input">>, Body, undefined) of
                undefined ->
                    throw({error, missing_input});
                I when is_binary(I) ->
                    [I];
                L when is_list(L) ->
                    lists:map(
                        fun
                            (B) when is_binary(B) -> B;
                            (_) -> throw({error, unsupported_input_type})
                        end,
                        L
                    );
                _ ->
                    throw({error, unsupported_input_type})
            end,
        KeepAlive = parse_keep_alive(maps:get(<<"keep_alive">>, Body, undefined)),
        {ok, #{model => Model, inputs => Inputs, keep_alive_ms => KeepAlive}}
    catch
        throw:{error, _} = E -> E
    end;
ollama_embed_to_internal(_) ->
    {error, invalid_json}.

%% Legacy shape (`POST /api/embeddings`, pre-Ollama-0.5):
%%   {"model": "...", "prompt": "text"} -> {"embedding": [...]}
-spec ollama_embeddings_legacy_to_internal(map()) ->
    {ok, #{model := binary(), inputs := [binary()], keep_alive_ms := term()}} | {error, term()}.
ollama_embeddings_legacy_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        Prompt = required_binary(Body, <<"prompt">>),
        KeepAlive = parse_keep_alive(maps:get(<<"keep_alive">>, Body, undefined)),
        {ok, #{model => Model, inputs => [Prompt], keep_alive_ms => KeepAlive}}
    catch
        throw:{error, _} = E -> E
    end;
ollama_embeddings_legacy_to_internal(_) ->
    {error, invalid_json}.

%% New /api/embed response: array of vectors + timing fields.
-spec internal_to_ollama_embed_response(binary(), [[float()]], non_neg_integer(), map()) ->
    iodata().
internal_to_ollama_embed_response(Model, Vectors, PromptTokens, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"embeddings">> => Vectors
            },
            embed_timing_fields(PromptTokens, Timings)
        )
    ).

%% Legacy /api/embeddings response: single vector under `embedding`.
-spec internal_to_ollama_embeddings_legacy_response(binary(), [float()], map()) -> iodata().
internal_to_ollama_embeddings_legacy_response(_Model, Vector, _Timings) ->
    json:encode(#{<<"embedding">> => Vector}).

embed_timing_fields(PromptTokens, Timings) ->
    #{
        <<"total_duration">> => maps:get(total_duration_ns, Timings, 0),
        <<"load_duration">> => maps:get(load_duration_ns, Timings, 0),
        <<"prompt_eval_count">> => PromptTokens
    }.

%% =============================================================================
%% keep_alive parsing
%%
%% Accepts:
%%   undefined / null -> undefined (caller falls back to server default)
%%   0                -> 0 (unload after this request)
%%   -1 | negative    -> infinity (never auto-unload)
%%   integer N        -> N seconds
%%   binary "5m"      -> 300_000 ms
%%   binary "30s"     -> 30_000 ms
%%   binary "1h"      -> 3_600_000 ms
%%   binary "0"       -> 0
%%   binary "-1"      -> infinity
%% =============================================================================

%% =============================================================================
%% response_format / format parsing
%% =============================================================================

%% OpenAI `response_format`:
%%   undefined         -> text
%%   {"type":"text"}   -> text
%%   {"type":"json_object"}                                -> json_object
%%   {"type":"json_schema", "json_schema": {"schema":...}} -> {json_schema, Schema}
%%
%% On a malformed value we fall back to `text` rather than 400 so SDKs
%% that pass extra unknown fields don't break.
-spec parse_response_format_openai(term()) ->
    text | json_object | {json_schema, map()}.
parse_response_format_openai(undefined) ->
    text;
parse_response_format_openai(null) ->
    text;
parse_response_format_openai(#{<<"type">> := <<"text">>}) ->
    text;
parse_response_format_openai(#{<<"type">> := <<"json_object">>}) ->
    json_object;
parse_response_format_openai(#{<<"type">> := <<"json_schema">>, <<"json_schema">> := JS}) when
    is_map(JS)
->
    case maps:get(<<"schema">>, JS, undefined) of
        S when is_map(S) -> {json_schema, S};
        _ -> json_object
    end;
parse_response_format_openai(_) ->
    text.

%% Ollama `format`:
%%   undefined / null       -> text
%%   "json"                 -> json_object
%%   <map> (JSON Schema)    -> {json_schema, Map}
-spec parse_response_format_ollama(term()) ->
    text | json_object | {json_schema, map()}.
parse_response_format_ollama(undefined) -> text;
parse_response_format_ollama(null) -> text;
parse_response_format_ollama(<<>>) -> text;
parse_response_format_ollama(<<"json">>) -> json_object;
parse_response_format_ollama(M) when is_map(M) -> {json_schema, M};
parse_response_format_ollama(_) -> text.

-spec parse_keep_alive(term()) -> non_neg_integer() | infinity | undefined.
parse_keep_alive(undefined) ->
    undefined;
parse_keep_alive(null) ->
    undefined;
parse_keep_alive(0) ->
    0;
parse_keep_alive(N) when is_integer(N), N < 0 ->
    infinity;
parse_keep_alive(N) when is_integer(N) ->
    N * 1000;
parse_keep_alive(F) when is_float(F) ->
    parse_keep_alive(trunc(F));
parse_keep_alive(B) when is_binary(B) ->
    parse_keep_alive_binary(string:trim(B));
parse_keep_alive(_) ->
    undefined.

parse_keep_alive_binary(<<>>) ->
    undefined;
parse_keep_alive_binary(<<"-", Rest/binary>>) ->
    case parse_keep_alive_unsigned(Rest) of
        undefined -> infinity;
        _N -> infinity
    end;
parse_keep_alive_binary(B) ->
    case parse_keep_alive_unsigned(B) of
        undefined -> undefined;
        N -> N
    end.

parse_keep_alive_unsigned(B) ->
    case binary:match(B, [<<"ms">>, <<"s">>, <<"m">>, <<"h">>]) of
        nomatch -> int_seconds(B);
        {Pos, Len} -> parse_unit(B, Pos, Len)
    end.

parse_unit(B, Pos, Len) ->
    NumPart = binary:part(B, 0, Pos),
    Unit = binary:part(B, Pos, Len),
    case parse_number(NumPart) of
        undefined -> undefined;
        N -> apply_unit(N, Unit)
    end.

apply_unit(N, <<"ms">>) -> N;
apply_unit(N, <<"s">>) -> N * 1000;
apply_unit(N, <<"m">>) -> N * 60 * 1000;
apply_unit(N, <<"h">>) -> N * 60 * 60 * 1000;
apply_unit(N, _) -> N * 1000.

parse_number(B) ->
    try
        case binary:match(B, <<".">>) of
            nomatch -> binary_to_integer(B);
            _ -> trunc(binary_to_float(B))
        end
    catch
        _:_ -> undefined
    end.

int_seconds(B) ->
    case parse_number(B) of
        undefined -> undefined;
        N -> N * 1000
    end.

%% =============================================================================
%% Ollama: response builders
%% =============================================================================

%% Streaming generate chunk: one JSON object per token. Caller writes
%% it as a single NDJSON line.
-spec internal_to_ollama_generate_chunk(binary(), binary(), binary()) -> iodata().
internal_to_ollama_generate_chunk(Token, _ReqId, Model) ->
    json:encode(#{
        <<"model">> => Model,
        <<"created_at">> => iso8601_now(),
        <<"response">> => Token,
        <<"done">> => false
    }).

%% Streaming generate final: emits the closing JSON with timing.
-spec internal_to_ollama_generate_final(map(), binary(), binary(), map()) -> iodata().
internal_to_ollama_generate_final(Stats, _ReqId, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"response">> => <<>>,
                <<"done">> => true,
                <<"done_reason">> => done_reason_atom(Stats)
            },
            timing_fields(Stats, Timings)
        )
    ).

%% Non-streaming generate response.
-spec internal_to_ollama_generate_response(binary(), map(), binary(), map()) -> iodata().
internal_to_ollama_generate_response(Body, Stats, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"response">> => Body,
                <<"done">> => true,
                <<"done_reason">> => done_reason_atom(Stats)
            },
            timing_fields(Stats, Timings)
        )
    ).

-spec internal_to_ollama_chat_chunk(binary(), binary(), binary()) -> iodata().
internal_to_ollama_chat_chunk(Token, _ReqId, Model) ->
    json:encode(#{
        <<"model">> => Model,
        <<"created_at">> => iso8601_now(),
        <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Token},
        <<"done">> => false
    }).

-spec internal_to_ollama_chat_final(map(), binary(), binary(), map()) -> iodata().
internal_to_ollama_chat_final(Stats, _ReqId, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<>>},
                <<"done">> => true,
                <<"done_reason">> => done_reason_atom(Stats)
            },
            timing_fields(Stats, Timings)
        )
    ).

-spec internal_to_ollama_chat_response(binary(), map(), binary(), map()) -> iodata().
internal_to_ollama_chat_response(Body, Stats, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Body},
                <<"done">> => true,
                <<"done_reason">> => done_reason_atom(Stats)
            },
            timing_fields(Stats, Timings)
        )
    ).

%% Preload / unload one-shot response. `Reason` is `<<"load">>` or
%% `<<"unload">>`.
-spec ollama_preload_response(generate | chat, binary(), binary(), map()) -> iodata().
ollama_preload_response(generate, Reason, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"response">> => <<>>,
                <<"done">> => true,
                <<"done_reason">> => Reason
            },
            timing_fields(#{}, Timings)
        )
    );
ollama_preload_response(chat, Reason, Model, Timings) ->
    json:encode(
        maps:merge(
            #{
                <<"model">> => Model,
                <<"created_at">> => iso8601_now(),
                <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<>>},
                <<"done">> => true,
                <<"done_reason">> => Reason
            },
            timing_fields(#{}, Timings)
        )
    ).

timing_fields(Stats, Timings) ->
    Base = #{
        <<"total_duration">> => maps:get(total_duration_ns, Timings, 0),
        <<"load_duration">> => maps:get(load_duration_ns, Timings, 0)
    },
    add_token_counts(Stats, Base).

add_token_counts(Stats, Base) ->
    maps:merge(Base, #{
        <<"prompt_eval_count">> => maps:get(prompt_tokens, Stats, 0),
        <<"eval_count">> => maps:get(completion_tokens, Stats, 0)
    }).

done_reason_atom(Stats) ->
    case maps:get(finish_reason, Stats, stop) of
        stop -> <<"stop">>;
        length -> <<"length">>;
        cancelled -> <<"cancelled">>;
        tool_call -> <<"tool_call">>;
        Other when is_atom(Other) -> atom_to_binary(Other, utf8);
        _ -> <<"stop">>
    end.

iso8601_now() ->
    Now = erlang:system_time(second),
    {{Y, Mo, D}, {H, M, S}} = calendar:system_time_to_universal_time(Now, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, M, S])
    ).

split_system(Messages) ->
    {SysParts, Rest} =
        lists:partition(
            fun
                (#{<<"role">> := <<"system">>}) -> true;
                (_) -> false
            end,
            Messages
        ),
    System =
        case SysParts of
            [] -> undefined;
            [_ | _] -> binary_join([content_to_text(M) || M <- SysParts], <<"\n\n">>)
        end,
    {System, [normalise_message(M) || M <- Rest]}.

normalise_message(M = #{<<"role">> := Role}) ->
    #{role => Role, content => content_value(maps:get(<<"content">>, M, <<>>))}.

%% Anthropic + OpenAI both accept content as either a plain string or
%% a list of typed blocks (text / image / tool_use / tool_result /
%% thinking). The underlying chat-template NIF only knows how to
%% render a binary, so we flatten blocks to a single text string on
%% the way in. Non-text blocks (images, tool envelopes) are dropped;
%% the surrounding tool-call grammar handles the structured paths.
content_value(B) when is_binary(B) -> B;
content_value(L) when is_list(L) -> flatten_content_blocks(L);
content_value(_) -> <<>>.

flatten_content_blocks(L) ->
    iolist_to_binary(
        lists:join(<<" ">>, [block_text(B) || B <- L, block_text(B) =/= <<>>])
    ).

block_text(#{<<"type">> := <<"text">>, <<"text">> := T}) when is_binary(T) -> T;
block_text(#{<<"text">> := T}) when is_binary(T) -> T;
block_text(#{<<"type">> := <<"tool_result">>} = Tr) -> tool_result_marker(Tr);
%% Assistant turns carrying a prior tool call: serialise to a stable
%% marker so the inference context preserves the fact that a tool was
%% called on a previous turn. The tool_result that follows on the next
%% turn pairs with this via the embedded id.
block_text(#{<<"type">> := <<"tool_use">>} = Tu) -> tool_use_marker(Tu);
%% Inputs we don't (yet) pipe to the model: image, document, thinking,
%% redacted_thinking, server_tool_use, web_search_tool_result,
%% search_result. The engine has no vision/audio path and thinking
%% blocks are an assistant-only construct; drop with no text
%% contribution. Explicit clauses (vs the catch-all) make this
%% intentional rather than silent.
block_text(#{<<"type">> := <<"image">>}) -> <<>>;
block_text(#{<<"type">> := <<"document">>}) -> <<>>;
block_text(#{<<"type">> := <<"thinking">>}) -> <<>>;
block_text(#{<<"type">> := <<"redacted_thinking">>}) -> <<>>;
block_text(#{<<"type">> := <<"server_tool_use">>}) -> <<>>;
block_text(#{<<"type">> := <<"web_search_tool_result">>}) -> <<>>;
block_text(#{<<"type">> := <<"search_result">>}) -> <<>>;
block_text(B) when is_binary(B) -> B;
block_text(_) -> <<>>.

tool_use_marker(#{<<"name">> := Name, <<"id">> := Id}) when
    is_binary(Name), is_binary(Id)
->
    <<"[tool_call name=", Name/binary, " id=", Id/binary, "]">>;
tool_use_marker(#{<<"name">> := Name}) when is_binary(Name) ->
    <<"[tool_call name=", Name/binary, "]">>;
tool_use_marker(_) ->
    <<"[tool_call]">>.

tool_result_text(B) when is_binary(B) -> B;
tool_result_text(L) when is_list(L) -> flatten_content_blocks(L);
tool_result_text(_) -> <<>>.

%% Wrap the tool_result content in a stable marker carrying the
%% tool_use_id (so the model can pair it with the matching tool_use
%% call) and an error flag when the caller marked the result as
%% errored. The content itself is flattened by tool_result_text.
tool_result_marker(Tr) ->
    Content = tool_result_text(maps:get(<<"content">>, Tr, <<>>)),
    IdPart =
        case maps:get(<<"tool_use_id">>, Tr, undefined) of
            Id when is_binary(Id) -> <<" id=", Id/binary>>;
            _ -> <<>>
        end,
    ErrorPart =
        case maps:get(<<"is_error">>, Tr, false) of
            true -> <<" error=true">>;
            _ -> <<>>
        end,
    <<"[tool_result", IdPart/binary, ErrorPart/binary, "]: ", Content/binary>>.

content_to_text(M) ->
    case maps:get(<<"content">>, M, <<>>) of
        B when is_binary(B) -> B;
        L when is_list(L) -> flatten_content_blocks(L);
        _ -> <<>>
    end.

binary_join([], _Sep) -> <<>>;
binary_join([H], _Sep) -> H;
binary_join([H | T], Sep) -> iolist_to_binary([H, [<<Sep/binary, X/binary>> || X <- T]]).

parse_anthropic_system(undefined) ->
    undefined;
parse_anthropic_system(B) when is_binary(B) -> B;
parse_anthropic_system(L) when is_list(L) ->
    iolist_to_binary(
        lists:join(
            <<"\n\n">>,
            [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- L]
        )
    ).

%% OpenAI tools: [{type:"function", function:{name, description, parameters}}]
parse_openai_tools(Body) ->
    case maps:get(<<"tools">>, Body, undefined) of
        undefined ->
            undefined;
        Tools when is_list(Tools) ->
            [
                #{
                    name => maps:get(<<"name">>, F),
                    description => maps:get(<<"description">>, F, <<>>),
                    schema => maps:get(<<"parameters">>, F, #{})
                }
             || #{<<"type">> := <<"function">>, <<"function">> := F} <- Tools
            ];
        _ ->
            undefined
    end.

parse_openai_tool_choice(Body) ->
    case maps:get(<<"tool_choice">>, Body, undefined) of
        undefined ->
            auto;
        <<"auto">> ->
            auto;
        <<"none">> ->
            none;
        <<"required">> ->
            required;
        #{
            <<"type">> := <<"function">>,
            <<"function">> := #{<<"name">> := Name}
        } ->
            {named, Name};
        _ ->
            auto
    end.

%% Anthropic tools: [{name, description, input_schema}]
parse_anthropic_tools(Body) ->
    case maps:get(<<"tools">>, Body, undefined) of
        undefined ->
            undefined;
        Tools when is_list(Tools) ->
            [
                #{
                    name => maps:get(<<"name">>, T),
                    description => maps:get(<<"description">>, T, <<>>),
                    schema => maps:get(<<"input_schema">>, T, #{})
                }
             || T <- Tools
            ];
        _ ->
            undefined
    end.

%% Anthropic prompt-caching markers can appear on:
%%   - system: [{type:"text", text, cache_control}]
%%   - tools[i].cache_control
%%   - messages[i].content[j].cache_control (any block kind)
%% We walk all three and emit a #{kind, hash} per marker. The hash is
%% the sha256 of the JSON-stable canonical form of the block content
%% (text or schema), so identical markers across turns produce the
%% same hash and the response builder can credit cache hits.
collect_cache_hints(System, MessagesIn, Body) ->
    SysHints = system_cache_hints(System),
    ToolHints = tools_cache_hints(maps:get(<<"tools">>, Body, undefined)),
    MsgHints = messages_cache_hints(MessagesIn),
    SysHints ++ ToolHints ++ MsgHints.

system_cache_hints(undefined) ->
    [];
system_cache_hints(B) when is_binary(B) -> [];
system_cache_hints(L) when is_list(L) ->
    [
        cache_hint(system, B, <<"system">>)
     || B <- L, has_cache_control(B)
    ].

tools_cache_hints(undefined) ->
    [];
tools_cache_hints(L) when is_list(L) ->
    [
        cache_hint(tool, T, <<"tool">>)
     || T <- L, is_map(T), has_cache_control(T)
    ].

messages_cache_hints(L) when is_list(L) ->
    lists:flatten([message_cache_hints(M) || M <- L]).

message_cache_hints(#{<<"content">> := Blocks}) when is_list(Blocks) ->
    [
        cache_hint(message, B, <<"message">>)
     || B <- Blocks, is_map(B), has_cache_control(B)
    ];
message_cache_hints(_) ->
    [].

has_cache_control(M) when is_map(M) ->
    maps:is_key(<<"cache_control">>, M);
has_cache_control(_) ->
    false.

cache_hint(Kind, Block, HashTag) ->
    #{
        kind => Kind,
        hash => block_hash(HashTag, Block),
        ttl => cache_control_ttl(Block)
    }.

%% Anthropic cache_control carries `ttl: "5m"` or `ttl: "1h"`.
%% Default to 5m when absent, matching Anthropic's spec.
cache_control_ttl(#{<<"cache_control">> := CC}) when is_map(CC) ->
    case maps:get(<<"ttl">>, CC, undefined) of
        <<"1h">> -> <<"1h">>;
        _ -> <<"5m">>
    end;
cache_control_ttl(_) ->
    <<"5m">>.

%% The hash covers the kind + a JSON-canonicalised view of the block
%% so re-ordered keys still match. We strip cache_control itself
%% before hashing — its TTL field isn't part of the content identity.
block_hash(Kind, Block) when is_map(Block) ->
    Stripped = maps:remove(<<"cache_control">>, Block),
    Canon = canonical_json(Stripped),
    crypto:hash(sha256, [Kind, $:, Canon]).

%% Order keys lexicographically so identical content with different
%% map iteration order hashes the same. Recurses into nested maps and
%% lists. Cheap enough for the few-KB blocks we expect.
canonical_json(M) when is_map(M) ->
    Pairs = lists:sort(maps:to_list(M)),
    [
        $\{,
        lists:join(
            $,,
            [[canonical_json(K), $:, canonical_json(V)] || {K, V} <- Pairs]
        ),
        $\}
    ];
canonical_json(L) when is_list(L) ->
    %% Distinguish JSON array from a binary written as a list. Erlang
    %% binaries hit the `is_binary` clause above; raw strings landed
    %% here only when caller passed an iolist, which we encode as the
    %% concatenated bytes (rare path; safe).
    case io_lib:printable_list(L) of
        true -> [$", L, $"];
        false -> [$[, lists:join($,, [canonical_json(X) || X <- L]), $]]
    end;
canonical_json(B) when is_binary(B) ->
    %% Escape only what JSON requires for hash stability; we never
    %% emit this for transport.
    [$", binary:replace(B, [<<"\"">>, <<"\\">>], <<"\\">>, [global]), $"];
canonical_json(N) when is_integer(N); is_float(N) ->
    io_lib:write(N);
canonical_json(true) ->
    <<"true">>;
canonical_json(false) ->
    <<"false">>;
canonical_json(null) ->
    <<"null">>;
canonical_json(undefined) ->
    <<"null">>.

parse_anthropic_tool_choice(Body) ->
    case maps:get(<<"tool_choice">>, Body, undefined) of
        undefined -> auto;
        #{<<"type">> := <<"auto">>} -> auto;
        #{<<"type">> := <<"any">>} -> required;
        #{<<"type">> := <<"tool">>, <<"name">> := N} -> {named, N};
        %% Anthropic-specific opt-out. The catch-all keeps falling back
        %% to auto, but explicit "none" must reach the grammar layer so
        %% no GBNF is installed for this request.
        #{<<"type">> := <<"none">>} -> none;
        _ -> auto
    end.

%% Anthropic's optional `metadata.user_id` is a free-form opaque
%% identifier the client sends for support diagnostics. We capture it
%% on the request record for observability.
parse_metadata_user_id(Body) ->
    case maps:get(<<"metadata">>, Body, undefined) of
        #{<<"user_id">> := U} when is_binary(U) -> U;
        _ -> undefined
    end.

parse_anthropic_thinking(Body) ->
    case maps:get(<<"thinking">>, Body, undefined) of
        undefined -> disabled;
        #{<<"type">> := <<"disabled">>} -> disabled;
        #{<<"type">> := <<"enabled">>} -> enabled;
        _ -> disabled
    end.

%% body.betas is the JSON-array equivalent of the anthropic-beta
%% header. Both opt into beta features; the handler merges the two
%% sources into one de-duplicated list on the request record.
parse_anthropic_betas_body(Body) ->
    case maps:get(<<"betas">>, Body, undefined) of
        L when is_list(L) ->
            [B || B <- L, is_binary(B), B =/= <<>>];
        _ ->
            []
    end.

%% Anthropic structured-outputs hook. `output_config.json_schema` is
%% the schema map directly (one level shallower than OpenAI's
%% `response_format.json_schema.schema`). Maps onto the same internal
%% `response_format` value the pipeline already feeds into
%% `erllama_server_grammar:from_response_format/1`.
parse_anthropic_output_config(Body) ->
    case maps:get(<<"output_config">>, Body, undefined) of
        #{<<"json_schema">> := Schema} when is_map(Schema) ->
            {json_schema, Schema};
        _ ->
            text
    end.

%% `thinking.display` defaults to "visible". "omitted" tells the server
%% to keep producing thinking on the engine side but not surface it on
%% the wire (no thinking_delta SSE, no thinking content block).
parse_anthropic_thinking_display(Body) ->
    case maps:get(<<"thinking">>, Body, undefined) of
        #{<<"display">> := <<"omitted">>} -> omitted;
        _ -> visible
    end.

%% `thinking.budget_tokens` is a hint for how many tokens the model is
%% allowed to spend on thinking. Captured for forward compat; the
%% engine has no budget surface yet.
parse_anthropic_thinking_budget(Body) ->
    case maps:get(<<"thinking">>, Body, undefined) of
        #{<<"budget_tokens">> := N} when is_integer(N), N > 0 -> N;
        _ -> undefined
    end.

required_binary(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined -> throw({error, {missing_field, Key}});
        B when is_binary(B) -> B;
        _ -> throw({error, {invalid_field, Key}})
    end.

check_messages_cap(L) when is_list(L) ->
    Cap = erllama_server_config:max_messages(),
    case length(L) > Cap of
        true -> throw({error, too_many_messages});
        false -> ok
    end.

check_tools_cap(undefined) ->
    ok;
check_tools_cap(L) when is_list(L) ->
    Cap = erllama_server_config:max_tools(),
    case length(L) > Cap of
        true -> throw({error, too_many_tools});
        false -> ok
    end.

required_list(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined -> throw({error, {missing_field, Key}});
        L when is_list(L) -> L;
        _ -> throw({error, {invalid_field, Key}})
    end.

parse_int(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        I when is_integer(I) -> I;
        _ -> Default
    end.

parse_optional_int(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined -> undefined;
        I when is_integer(I) -> I;
        _ -> undefined
    end.

parse_float(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        F when is_float(F) -> F;
        I when is_integer(I) -> float(I);
        _ -> Default
    end.

parse_bool(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        true -> true;
        false -> false;
        _ -> Default
    end.

parse_stop(Body) ->
    case maps:get(<<"stop">>, Body, undefined) of
        undefined -> [];
        B when is_binary(B) -> [B];
        L when is_list(L) -> [X || X <- L, is_binary(X)];
        _ -> []
    end.

%% Anthropic's `/v1/messages` uses `stop_sequences` (plural, list-only).
%% Same semantics as OpenAI's `stop`: generation halts on a match.
parse_stop_sequences(Body) ->
    case maps:get(<<"stop_sequences">>, Body, undefined) of
        L when is_list(L) -> [X || X <- L, is_binary(X)];
        _ -> []
    end.

finish_reason_atom(Stats) ->
    case maps:get(finish_reason, Stats, stop) of
        stop -> <<"stop">>;
        length -> <<"length">>;
        cancelled -> <<"stop">>;
        tool_call -> <<"tool_calls">>;
        _ -> <<"stop">>
    end.

anthropic_stop_reason(Stats) ->
    case maps:get(finish_reason, Stats, stop) of
        stop ->
            %% erllama 0.3.0 reports the matched stop string in
            %% `stop_sequence` when generation halted on a caller-supplied
            %% stop. Map to Anthropic's distinct `stop_sequence` reason in
            %% that case; otherwise it's a natural end-of-generation.
            case maps:is_key(stop_sequence, Stats) of
                true -> <<"stop_sequence">>;
                false -> <<"end_turn">>
            end;
        length ->
            <<"max_tokens">>;
        cancelled ->
            <<"end_turn">>;
        tool_call ->
            <<"tool_use">>;
        _ ->
            <<"end_turn">>
    end.

%% `stop_sequence` value as required by Anthropic when the matching
%% reason is `stop_sequence`; absent in Stats otherwise (engine reports
%% the matched binary only when a caller-supplied stop fired).
anthropic_stop_sequence(Stats) ->
    case maps:get(stop_sequence, Stats, undefined) of
        undefined -> null;
        Bin when is_binary(Bin) -> Bin
    end.

usage_map(Stats) ->
    Prompt = maps:get(prompt_tokens, Stats, 0),
    Completion = maps:get(completion_tokens, Stats, 0),
    Base = #{
        <<"prompt_tokens">> => Prompt,
        <<"completion_tokens">> => Completion,
        <<"total_tokens">> => Prompt + Completion
    },
    %% OpenAI surfaces cache stats via `prompt_tokens_details.cached_tokens`
    %% (the field the OpenAI Python SDK reads). Populate it from the
    %% Stats `cache_hit_kind` flag erllama exposes so SDKs that
    %% observe cache hits show real numbers.
    case cached_tokens(Stats) of
        0 -> Base;
        N -> Base#{<<"prompt_tokens_details">> => #{<<"cached_tokens">> => N}}
    end.

%% erllama 0.4.0 surfaces accurate per-request cache token deltas
%% under `Stats.cache_delta = #{read, created}`. Read maps to
%% Anthropic's cache_read_input_tokens, created to
%% cache_creation_input_tokens. The whole-prompt approximation we
%% used before is gone.
cached_tokens(Stats) ->
    Delta = maps:get(cache_delta, Stats, #{}),
    maps:get(read, Delta, 0).

cache_creation_tokens(Stats) ->
    Delta = maps:get(cache_delta, Stats, #{}),
    maps:get(created, Delta, 0).

unix_seconds() -> erlang:system_time(second).

make_id(Prefix) ->
    iolist_to_binary([Prefix, integer_to_binary(erlang:unique_integer([positive]))]).

index_zero(L) -> index_zero(L, 0).
index_zero([], _) -> [];
index_zero([H | T], I) -> [{I, H} | index_zero(T, I + 1)].

%% Render an Anthropic SSE event (named event + data line).
sse(EventName, Payload) ->
    [<<"event: ">>, EventName, <<"\ndata: ">>, json:encode(Payload), <<"\n\n">>].
