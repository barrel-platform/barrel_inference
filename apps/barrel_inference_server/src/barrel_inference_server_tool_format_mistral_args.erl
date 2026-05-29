%%% mistral-args tool-call format. Used by Mistral models from the
%%% tekken tokenizer (v11+): Devstral-Small-2 (2507, 2512),
%%% Mistral-Small-3.1 / 3.2, Magistral, Ministral, recent Codestral.
%%% Each call is rendered as:
%%%
%%%   [TOOL_CALLS]<name>[ARGS]<json-args>
%%%
%%% with the per-call sequence repeated and terminated by the model's
%%% EOS token (`</s>`):
%%%
%%%   [TOOL_CALLS]a[ARGS]{}[TOOL_CALLS]b[ARGS]{"x":1}</s>
%%%
%%% Parallel calls flow through the engine via the span-split clause in
%%% `barrel_inference_model:apply_step_results/2`: each `[TOOL_CALLS]`
%%% finalises the open span before opening the next, so the family
%%% parser sees one call per `parse/1` invocation and the upstream
%%% handler accumulates them into `captured_calls`.
%%%
%%% Capture nuance: the engine detokenises with `special=false`
%%% (`barrel_inference_nif.c`), so control-token markers like
%%% `[TOOL_CALLS]` and `[ARGS]` are DROPPED from the captured FullBin.
%%% The actual real-backend body the parser sees is typically
%%% `name{json}` with no marker text. The parser tolerates both shapes:
%%% it strips an optional `[TOOL_CALLS]` prefix, splits on `[ARGS]` if
%%% present, otherwise on the first `{` / `[`. EOS is stripped
%%% defensively, mirroring `mistral_tool_calls`.

-module(barrel_inference_server_tool_format_mistral_args).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).

-define(START, <<"[TOOL_CALLS]">>).
-define(ARGS, <<"[ARGS]">>).
-define(EOS, <<"</s>">>).

%% Native tool system block: the tekken chat template wraps tool
%% signatures in [AVAILABLE_TOOLS]...[/AVAILABLE_TOOLS] and instructs
%% the model to emit calls as [TOOL_CALLS]<name>[ARGS]<json>.
-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = [
        <<"[AVAILABLE_TOOLS]">>,
        json:encode(Sigs),
        <<"[/AVAILABLE_TOOLS]\n\n">>,
        <<"To call a function, respond with a tool-call sequence in exactly ">>,
        <<"this format (repeat per call):\n">>,
        ?START,
        <<"<function-name>">>,
        ?ARGS,
        <<"<args-json-object>">>
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Body = strip_prefix(string:trim(Bin), ?START),
    {Name, JsonBin} =
        case binary:split(Body, ?ARGS) of
            [N, J] -> {string:trim(N), J};
            _ -> split_at_first_brace(Body)
        end,
    case Name of
        <<>> -> {error, no_name};
        _ -> decode_args(Name, string:trim(JsonBin))
    end.

%% Real-backend (control-token detok drops markers) shape: the body
%% looks like `name{json}` with no `[ARGS]` separator. Find the first
%% JSON open-brace / open-bracket, take everything before as the name,
%% the rest as the args region.
split_at_first_brace(Bin) ->
    case binary:match(Bin, [<<"{">>, <<"[">>]) of
        nomatch ->
            {string:trim(Bin), <<>>};
        {Pos, _Len} ->
            Name = string:trim(binary:part(Bin, 0, Pos)),
            Json = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            {Name, Json}
    end.

%% The tekken template always renders `[ARGS]` followed by an arguments
%% string (defaults to `{}` for zero-arg calls), so an empty JsonBin is
%% a truncated capture - reject rather than coerce to `{}` and surface
%% a fake tool use to the caller.
decode_args(_Name, <<>>) ->
    {error, empty_args};
decode_args(Name, Json0) ->
    Json = strip_eos(Json0),
    try json:decode(Json) of
        Args when is_map(Args) -> {ok, #{name => Name, arguments => Args}};
        _ -> {error, args_not_object}
    catch
        _:_ -> {error, invalid_json}
    end.

%% The wire ends at `</s>` (eos). On the native-capture path the engine
%% omits the end token from the body, but the captured FullBin (or a
%% raw scanner region) may still trail it - strip defensively,
%% mirroring `mistral_tool_calls`.
strip_eos(B) ->
    Trimmed = string:trim(B),
    Sz = byte_size(Trimmed),
    case Sz >= 4 andalso binary:part(Trimmed, Sz - 4, 4) =:= ?EOS of
        true -> string:trim(binary:part(Trimmed, 0, Sz - 4));
        false -> Trimmed
    end.

%% Tolerant prefix strip: returns the input unchanged if Prefix is not
%% present, so the real `name{json}` capture path (control-token markers
%% dropped) is NOT accidentally required to carry `[TOOL_CALLS]`.
strip_prefix(Bin, Prefix) ->
    PSz = byte_size(Prefix),
    case Bin of
        <<P:PSz/binary, Rest/binary>> when P =:= Prefix -> Rest;
        _ -> Bin
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([?START, Name, ?ARGS, json:encode(Args)]).
