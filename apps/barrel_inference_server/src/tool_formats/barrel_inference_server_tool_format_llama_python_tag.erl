%%% llama_python_tag tool-call format. Used by Llama 3.1 / 3.2 / 3.3
%%% when emitting tool calls via the `<|python_tag|>' special token.
%%% Body is a single JSON object with `name' and `parameters' keys,
%%% terminated by `<|eom_id|>':
%%%
%%%   <|python_tag|>{"name":"get_weather","parameters":{"city":"Paris"}}<|eom_id|>
%%%
%%% Llama 3.x uses `parameters' rather than `arguments' as the args
%%% key; the parser accepts either, and the canonicaliser emits
%%% `parameters' (which is the form the model itself produces and the
%%% form prompt templates expect on history replay).
%%%
%%% The parser tolerates leading / trailing whitespace and a missing
%%% `<|eom_id|>' terminator (some configs end the call at the model's
%%% EOS token without re-emitting eom_id into the wire).
%%%
%%% Spec source: Llama 3.1 model card and Meta's llama-stack tool
%%% prompt format documentation. Runtime verification against a real
%%% Llama 3.x backend is recommended before relying on the
%%% canonicaliser for byte-exact replay.

-module(barrel_inference_server_tool_format_llama_python_tag).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([family_name/0, detect/1]).

-define(START, <<"<|python_tag|>">>).
-define(END, <<"<|eom_id|>">>).

family_name() -> <<"llama-python-tag">>.

%% Llama 3.1 carries the `<|python_tag|>' marker; 3.2 / 3.3 use the
%% marker-less pythonic family (`llama-pythonic') which sits earlier
%% in `?BARREL_TOOL_FORMAT_FAMILIES'.
-spec detect(binary()) ->
    {detected, #{start := binary(), 'end' := binary()}} | not_detected.
detect(T) when is_binary(T) ->
    case binary:match(T, ?START) of
        nomatch -> not_detected;
        _ -> {detected, #{start => ?START, 'end' => ?END}}
    end.

%% Native tool system block matching the Llama 3.1 JSON tool format.
%% Llama uses `parameters' (not `arguments') as the args key and emits
%% the call after the <|python_tag|> marker the engine captures.
-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = [
        <<"# Tools\n\n">>,
        <<"You have access to the following functions:\n">>,
        [[json:encode(S), <<"\n">>] || S <- Sigs],
        <<"\nTo call a function, respond with a JSON object after the ">>,
        <<"<|python_tag|> token in exactly this format:\n">>,
        ?START,
        <<"{\"name\": <function-name>, \"parameters\": <args-json-object>}">>,
        ?END
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    %% Tolerant of the marker-stripped real-backend shape: the NIF
    %% detokenizer's `special=false' drops `<|python_tag|>' and
    %% `<|eom_id|>' (both control tokens) from the captured FullBin, so
    %% the parser accepts both the canonical
    %% `<|python_tag|>{json}<|eom_id|>' AND a bare `{json}'.
    Body = barrel_inference_server_tool_format:strip_suffix(
        barrel_inference_server_tool_format:strip_prefix(
            string:trim(Bin), ?START
        ),
        ?END
    ),
    decode_payload(string:trim(Body)).

decode_payload(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"parameters">> := Args} when
            is_binary(Name), is_map(Args)
        ->
            {ok, #{name => Name, arguments => Args}};
        #{<<"name">> := Name, <<"arguments">> := Args} when
            is_binary(Name), is_map(Args)
        ->
            %% Tolerate the OpenAI-style `arguments' key seen on some
            %% Llama 3.x fine-tunes.
            {ok, #{name => Name, arguments => Args}};
        #{<<"name">> := Name} when is_binary(Name) ->
            {ok, #{name => Name, arguments => #{}}};
        _ ->
            {error, malformed_payload}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([
        ?START,
        json:encode(#{<<"name">> => Name, <<"parameters">> => Args}),
        ?END
    ]).
