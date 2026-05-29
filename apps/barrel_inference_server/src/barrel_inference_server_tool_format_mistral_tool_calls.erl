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

-module(barrel_inference_server_tool_format_mistral_tool_calls).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).

-define(START, <<"[TOOL_CALLS]">>).
-define(EOS, <<"</s>">>).

%% Native tool system block matching the Mistral v3 tokenizer chat
%% template: tools as a JSON array inside [AVAILABLE_TOOLS]...
%% [/AVAILABLE_TOOLS], calls emitted as [TOOL_CALLS][{...}] (the marker
%% the engine captures). Mistral carries multiple calls in one array.
-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = [
        <<"[AVAILABLE_TOOLS]">>,
        json:encode(Sigs),
        <<"[/AVAILABLE_TOOLS]\n\n">>,
        <<"To call functions, respond with a JSON array of calls after the ">>,
        <<"[TOOL_CALLS] token in exactly this format:\n">>,
        ?START,
        <<"[{\"name\": <function-name>, \"arguments\": <args-json-object>}]">>
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    %% Tolerant of the marker-stripped real-backend shape: the NIF
    %% detokenizer's `special=false' drops `[TOOL_CALLS]' and `</s>'
    %% (both control tokens) from the captured FullBin, so the parser
    %% accepts both `[TOOL_CALLS][...]</s>' AND a bare `[...]' (the
    %% JSON array, possibly with an `</s>' trailer).
    Body = barrel_inference_server_tool_format:strip_suffix(
        barrel_inference_server_tool_format:strip_prefix(
            string:trim(Bin), ?START
        ),
        ?EOS
    ),
    decode_first_call(string:trim(Body)).

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
