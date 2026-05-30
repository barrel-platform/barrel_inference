%%% qwen-xml tool-call format. Used by Qwen3 / Qwen2.5 models that
%%% wrap a JSON object between literal `<tool_call>...</tool_call>'
%%% markers:
%%%
%%%   <tool_call>{"name":"foo","arguments":{"x":1}}</tool_call>
%%%
%%% The parser is tolerant of leading / trailing whitespace and of
%%% Hermes-style variants that emit `arguments' as a JSON-encoded
%%% string (some Qwen2.5 fine-tunes do this).

-module(barrel_inference_server_tool_format_qwen_xml).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([family_name/0, detect/1]).

-define(START, <<"<tool_call>">>).
-define(END, <<"</tool_call>">>).

family_name() -> <<"qwen-xml">>.

%% Generic `<tool_call>...</tool_call>' shape (Qwen2.5 / Qwen3
%% lineage). Specific siblings (`qwen3-coder', `glm45') sit earlier
%% in `?BARREL_TOOL_FORMAT_FAMILIES' so they win when their extra
%% substring is present; this single-substring predicate is the
%% fall-through.
-spec detect(binary()) ->
    {detected, #{start := binary(), 'end' := binary()}} | not_detected.
detect(T) when is_binary(T) ->
    case binary:match(T, ?START) of
        nomatch -> not_detected;
        _ -> {detected, #{start => ?START, 'end' => ?END}}
    end.

%% Native tool system block matching the Qwen2.5 / Qwen3 chat template:
%% function signatures inside <tools></tools>, calls emitted as
%% <tool_call>{json}</tool_call> (the markers the engine captures).
-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = [
        <<"# Tools\n\n">>,
        <<"You may call one or more functions to assist with the user query.\n\n">>,
        <<"You are provided with function signatures within <tools></tools> XML tags:\n">>,
        <<"<tools>\n">>,
        [[json:encode(S), <<"\n">>] || S <- Sigs],
        <<"</tools>\n\n">>,
        <<"For each function call, return a json object with function name and ">>,
        <<"arguments within <tool_call></tool_call> XML tags:\n">>,
        ?START,
        <<"\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n">>,
        ?END
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

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
