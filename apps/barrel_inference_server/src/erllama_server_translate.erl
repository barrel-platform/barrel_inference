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
    message_start
    | content_block_start_text
    | {text_delta, binary()}
    | {thinking_delta, binary()}
    | content_block_stop
    | {message_delta, map()}
    | message_stop.

-export_type([anthropic_event_kind/0]).

-export([
    %% request: in
    openai_chat_to_internal/1,
    openai_completion_to_internal/1,
    openai_embeddings_to_internal/1,
    anthropic_messages_to_internal/1,
    %% response: out
    internal_to_openai_chat_response/3,
    internal_to_openai_chat_chunk/3,
    internal_to_openai_reasoning_chunk/3,
    internal_to_openai_chat_final/3,
    internal_to_openai_completion_response/3,
    internal_to_openai_embedding_response/3,
    internal_to_anthropic_messages_response/3,
    internal_to_anthropic_event/4
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
        Base = base_request(Body, openai),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = Messages,
            prompt = undefined,
            system = System,
            tools = Tools,
            tool_choice = ToolChoice
        }}
    catch
        throw:{error, _} = E -> E
    end;
openai_chat_to_internal(_) ->
    {error, invalid_json}.

-spec openai_completion_to_internal(map()) ->
    {ok, #erllama_request{}} | {error, term()}.
openai_completion_to_internal(Body) when is_map(Body) ->
    try
        Model = required_binary(Body, <<"model">>),
        Prompt = required_binary(Body, <<"prompt">>),
        Base = base_request(Body, openai),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = [],
            prompt = Prompt,
            system = undefined,
            tools = undefined,
            tool_choice = none
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
        Base = base_request(Body, anthropic),
        {ok, Base#erllama_request{
            model_id = Model,
            messages = Messages,
            prompt = undefined,
            system = System,
            tools = Tools,
            tool_choice = ToolChoice,
            thinking = Thinking
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

%% Final SSE frame for an OpenAI chat completion. Emits an empty
%% delta with finish_reason set; the caller appends `[DONE]` after.
-spec internal_to_openai_chat_final(map(), binary(), binary()) -> iodata().
internal_to_openai_chat_final(Stats, ReqId, Model) ->
    Created = unix_seconds(),
    Final = #{
        <<"id">> => ReqId,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{},
                <<"finish_reason">> => finish_reason_atom(Stats)
            }
        ],
        <<"usage">> => usage_map(Stats)
    },
    json:encode(Final).

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

%% Non-streaming Anthropic /v1/messages response.
-spec internal_to_anthropic_messages_response(binary(), map(), binary()) -> map().
internal_to_anthropic_messages_response(Text, Stats, Model) ->
    #{
        <<"id">> => make_id(<<"msg_">>),
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => Model,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => Text}],
        <<"stop_reason">> => anthropic_stop_reason(Stats),
        <<"stop_sequence">> => null,
        <<"usage">> => #{
            <<"input_tokens">> => maps:get(prompt_tokens, Stats, 0),
            <<"output_tokens">> => maps:get(completion_tokens, Stats, 0)
        }
    }.

%% Anthropic SSE event encoder. Returns iolist containing
%% `event: <name>\ndata: <json>\n\n`.
-spec internal_to_anthropic_event(
    anthropic_event_kind(), map(), binary(), binary()
) -> iodata().
internal_to_anthropic_event(message_start, _Acc, ReqId, Model) ->
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
            <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}
        }
    },
    sse(<<"message_start">>, Payload);
internal_to_anthropic_event(content_block_start_text, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_start">>,
        #{
            <<"type">> => <<"content_block_start">>,
            <<"index">> => 0,
            <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
        }
    );
internal_to_anthropic_event({text_delta, Bin}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_delta">>,
        #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => 0,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Bin}
        }
    );
internal_to_anthropic_event({thinking_delta, Bin}, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_delta">>,
        #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => 0,
            <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => Bin}
        }
    );
internal_to_anthropic_event(content_block_stop, _Acc, _ReqId, _Model) ->
    sse(
        <<"content_block_stop">>,
        #{<<"type">> => <<"content_block_stop">>, <<"index">> => 0}
    );
internal_to_anthropic_event({message_delta, Stats}, _Acc, _ReqId, _Model) ->
    sse(
        <<"message_delta">>,
        #{
            <<"type">> => <<"message_delta">>,
            <<"delta">> => #{
                <<"stop_reason">> => anthropic_stop_reason(Stats),
                <<"stop_sequence">> => null
            },
            <<"usage">> => #{
                <<"output_tokens">> => maps:get(completion_tokens, Stats, 0)
            }
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
        request_id = make_id(prefix_for(Api))
    }.

prefix_for(openai) -> <<"chatcmpl-">>;
prefix_for(anthropic) -> <<"msg_">>.

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

content_value(B) when is_binary(B) -> B;
content_value(L) when is_list(L) -> L;
content_value(_) -> <<>>.

content_to_text(M) ->
    case maps:get(<<"content">>, M, <<>>) of
        B when is_binary(B) -> B;
        L when is_list(L) ->
            iolist_to_binary(
                lists:join(
                    <<" ">>,
                    [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- L]
                )
            );
        _ ->
            <<>>
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

parse_anthropic_tool_choice(Body) ->
    case maps:get(<<"tool_choice">>, Body, undefined) of
        undefined -> auto;
        #{<<"type">> := <<"auto">>} -> auto;
        #{<<"type">> := <<"any">>} -> required;
        #{<<"type">> := <<"tool">>, <<"name">> := N} -> {named, N};
        _ -> auto
    end.

parse_anthropic_thinking(Body) ->
    case maps:get(<<"thinking">>, Body, undefined) of
        undefined -> disabled;
        #{<<"type">> := <<"disabled">>} -> disabled;
        #{<<"type">> := <<"enabled">>} -> enabled;
        _ -> disabled
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
        stop -> <<"end_turn">>;
        length -> <<"max_tokens">>;
        cancelled -> <<"end_turn">>;
        tool_call -> <<"tool_use">>;
        _ -> <<"end_turn">>
    end.

usage_map(Stats) ->
    Prompt = maps:get(prompt_tokens, Stats, 0),
    Completion = maps:get(completion_tokens, Stats, 0),
    #{
        <<"prompt_tokens">> => Prompt,
        <<"completion_tokens">> => Completion,
        <<"total_tokens">> => Prompt + Completion
    }.

unix_seconds() -> erlang:system_time(second).

make_id(Prefix) ->
    iolist_to_binary([Prefix, integer_to_binary(erlang:unique_integer([positive]))]).

index_zero(L) -> index_zero(L, 0).
index_zero([], _) -> [];
index_zero([H | T], I) -> [{I, H} | index_zero(T, I + 1)].

%% Render an Anthropic SSE event (named event + data line).
sse(EventName, Payload) ->
    [<<"event: ">>, EventName, <<"\ndata: ">>, json:encode(Payload), <<"\n\n">>].
