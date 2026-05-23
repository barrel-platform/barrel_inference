%%% qwen-xml tool-call format. Used by Qwen3 / Qwen2.5 models that
%%% wrap a JSON object between literal `<tool_call>...</tool_call>'
%%% markers:
%%%
%%%   <tool_call>{"name":"foo","arguments":{"x":1}}</tool_call>
%%%
%%% The parser is tolerant of leading / trailing whitespace and of
%%% Hermes-style variants that emit `arguments' as a JSON-encoded
%%% string (some Qwen2.5 fine-tunes do this).

-module(erllama_server_tool_format_qwen_xml).
-behaviour(erllama_server_tool_format).

-export([parse/1, canonicalise/1]).

-define(START, <<"<tool_call>">>).
-define(END, <<"</tool_call>">>).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    case extract_payload(Bin) of
        {ok, JsonBin} -> decode_payload(JsonBin);
        error -> {error, no_markers}
    end.

extract_payload(Bin) ->
    case binary:split(Bin, ?START) of
        [_, AfterStart] ->
            case binary:split(AfterStart, ?END) of
                [Payload, _] -> {ok, string:trim(Payload)};
                _ -> error
            end;
        _ ->
            error
    end.

decode_payload(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} when
            is_binary(Name), is_map(Args)
        ->
            {ok, #{name => Name, arguments => Args}};
        #{<<"name">> := Name, <<"arguments">> := ArgsStr} when
            is_binary(Name), is_binary(ArgsStr)
        ->
            %% Hermes-style: arguments is a JSON-encoded string.
            decode_string_arguments(Name, ArgsStr);
        #{<<"name">> := Name} when is_binary(Name) ->
            {ok, #{name => Name, arguments => #{}}};
        _ ->
            {error, malformed_payload}
    catch
        _:_ -> {error, invalid_json}
    end.

decode_string_arguments(Name, ArgsStr) ->
    try json:decode(ArgsStr) of
        M when is_map(M) -> {ok, #{name => Name, arguments => M}};
        _ -> {error, malformed_arguments}
    catch
        _:_ -> {error, invalid_arguments_json}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([
        ?START,
        json:encode(#{<<"name">> => Name, <<"arguments">> => Args}),
        ?END
    ]).
