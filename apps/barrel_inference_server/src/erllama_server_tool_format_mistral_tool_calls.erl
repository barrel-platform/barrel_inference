%%% mistral-tool-calls tool-call format. Used by Mistral / Mixtral
%%% models from the v3 tokenizer onward. The format starts with the
%%% `[TOOL_CALLS]' special token followed by a JSON ARRAY of call
%%% objects, terminated by the model's EOS token (`</s>'):
%%%
%%%   [TOOL_CALLS][{"name":"f","arguments":{"x":1}}]</s>
%%%
%%% Unlike qwen-xml / dsml / llama-python-tag, the array may carry
%%% multiple calls in a single span:
%%%
%%%   [TOOL_CALLS][{"name":"a","arguments":{}},{"name":"b","arguments":{}}]</s>
%%%
%%% This module's parser returns the FIRST call in the array; multi-
%%% call extraction will be revisited once PR 5's capture path is
%%% live and we can ground-truth against a real Mistral backend (the
%%% behaviour callback signature would have to widen to `[map()]' if
%%% we want to capture all of them). Note flagged inline in
%%% `parse/1' for future-me.
%%%
%%% The parser tolerates:
%%%   - presence or absence of the trailing `</s>' EOS token
%%%   - leading / trailing whitespace
%%%
%%% Spec source: the public Mistral v3 tokenizer chat template
%%% (mistral-common). Runtime verification against a real Mistral
%%% backend is recommended before relying on the canonicaliser for
%%% byte-exact replay.

-module(erllama_server_tool_format_mistral_tool_calls).
-behaviour(erllama_server_tool_format).

-export([parse/1, canonicalise/1]).

-define(START, <<"[TOOL_CALLS]">>).
-define(EOS, <<"</s>">>).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    case extract_array(string:trim(Bin)) of
        {ok, ArrayBin} -> decode_first_call(string:trim(ArrayBin));
        error -> {error, no_markers}
    end.

extract_array(Bin) ->
    case binary:split(Bin, ?START) of
        [_, AfterStart] ->
            %% EOS is optional - strip it if present.
            case binary:split(AfterStart, ?EOS) of
                [Body, _] -> {ok, Body};
                _ -> {ok, AfterStart}
            end;
        _ ->
            error
    end.

decode_first_call(JsonBin) ->
    try json:decode(JsonBin) of
        [First | _Rest] when is_map(First) ->
            %% PR 3d returns only the first call; multi-call extraction
            %% is deferred until PR 5 surfaces the real need.
            extract_call(First);
        [_ | _] ->
            {error, malformed_call_entry};
        [] ->
            {error, empty_array};
        _ ->
            {error, not_an_array}
    catch
        _:_ -> {error, invalid_json}
    end.

extract_call(#{<<"name">> := Name, <<"arguments">> := Args}) when
    is_binary(Name), is_map(Args)
->
    {ok, #{name => Name, arguments => Args}};
extract_call(#{<<"name">> := Name, <<"parameters">> := Args}) when
    is_binary(Name), is_map(Args)
->
    %% Some fine-tunes use `parameters' instead.
    {ok, #{name => Name, arguments => Args}};
extract_call(#{<<"name">> := Name}) when is_binary(Name) ->
    {ok, #{name => Name, arguments => #{}}};
extract_call(_) ->
    {error, malformed_call}.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([
        ?START,
        json:encode([#{<<"name">> => Name, <<"arguments">> => Args}]),
        ?EOS
    ]).
