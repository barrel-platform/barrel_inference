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
    ollama_generate_to_internal/1,
    ollama_chat_to_internal/1,
    ollama_embed_to_internal/1,
    ollama_embeddings_legacy_to_internal/1,
    %% response: out
    internal_to_openai_chat_response/3,
    internal_to_openai_chat_chunk/3,
    internal_to_openai_reasoning_chunk/3,
    internal_to_openai_chat_final/3,
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
    %% helpers
    parse_keep_alive/1,
    parse_response_format_openai/1,
    parse_response_format_ollama/1
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
