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
    Body = barrel_inference_server_tool_format:strip_prefix(
        string:trim(Bin), ?START
    ),
    {Name, JsonBin} =
        case binary:split(Body, ?ARGS) of
            [N, J] -> {string:trim(N), J};
            _ -> barrel_inference_server_tool_format:split_at_first_brace(Body)
        end,
    case Name of
        <<>> -> {error, no_name};
        _ -> decode_args(Name, string:trim(JsonBin))
    end.

%% The tekken template always renders `[ARGS]` followed by an arguments
%% string (defaults to `{}` for zero-arg calls), so an empty JsonBin is
%% a truncated capture - reject rather than coerce to `{}` and surface
%% a fake tool use to the caller.
decode_args(_Name, <<>>) ->
    {error, empty_args};
decode_args(Name, Json0) ->
    Json = barrel_inference_server_tool_format:strip_suffix(Json0, ?EOS),
    try json:decode(Json) of
        Args when is_map(Args) -> {ok, #{name => Name, arguments => Args}};
        _ -> {error, args_not_object}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([?START, Name, ?ARGS, json:encode(Args)]).
