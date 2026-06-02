%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_autoparser).
-moduledoc """
Shared handler-side autoparser bridge.

Each of `barrel_inference_server_h_chat', `barrel_inference_server_h_messages',
and `barrel_inference_server_h_responses' calls `maybe_extract/4'
on `barrel_inference_done'. The bridge takes the `ParamsRef'
that the pipeline built at admit time (and carried admit -> done
on the `{pipeline, templated, Tokens, ParamsRef}' message),
parses the buffered response text via llama.cpp's autoparser,
and translates each `tool_call' into the handler's captured-call
shape (`#{id, name, input, full_bin}').

This is now the PRIMARY path. The engine's per-token marker
scanner is gone; tool-call classification happens once, post-decode,
via `barrel_inference:chat_parse/3'.

The bridge short-circuits to `none' (no NIF call) when:
- `ParamsRef' is `undefined' (raw-prompt path; no autoparser was
  set up at admit time), OR
- the request's `tools' field is `undefined' / `[]' (no tools were
  requested; no work to do).

`build_inputs(Request)' is the canonical Inputs shape; the
pipeline also calls it to render the prompt. The autoparser NIF
expects a map with `messages' (JSON binary, with system folded
in), `tools' (JSON binary), `tool_choice' (atom), and
`parallel_tool_calls' (atom).
""".

-include_lib("barrel_inference_server/include/barrel_inference_server.hrl").

-export([maybe_extract/4, build_inputs/1]).

-export_type([captured_call/0]).

-type captured_call() :: #{
    id := binary(),
    name := binary(),
    input := map(),
    full_bin := binary()
}.

%% Attempt to extract tool calls from BufText using the carried
%% ParamsRef. Returns `{ok, [Call]}' on a non-empty extraction,
%% `none' otherwise (params undefined, no tools requested, parser
%% returned no tool calls, or any error).
-spec maybe_extract(
    ParamsRef :: undefined | barrel_inference_nif:chat_params_ref(),
    Request :: #barrel_inference_request{},
    BufText :: iodata(),
    ApiHint :: openai | anthropic
) ->
    {ok, [captured_call()]} | none.
maybe_extract(undefined, _Request, _BufText, _Api) ->
    none;
maybe_extract(_Params, #barrel_inference_request{tools = undefined}, _BufText, _Api) ->
    none;
maybe_extract(_Params, #barrel_inference_request{tools = []}, _BufText, _Api) ->
    none;
maybe_extract(Params, _Request, BufText, _Api) ->
    BufBin = iolist_to_binary(BufText),
    case barrel_inference:chat_parse(Params, BufBin, false) of
        {ok, #{tool_calls := [_ | _] = Calls}} ->
            {ok, [translate(C, BufBin) || C <- Calls]};
        _ ->
            none
    end.

%% Canonical Inputs builder used by BOTH the pipeline (prompt
%% render) AND the autoparser bridge (well, used to - the bridge
%% now uses the carried params and doesn't need this). The pipeline
%% imports it from here so prompt-render and parse share one shape.
%%
%% Behaviour:
%% - `messages' (JSON binary) is the user-supplied list prepended
%%   with a synthetic `system' message when `Request.system' is
%%   non-empty (the NIF reads only `messages'; `system' is not a
%%   separate Inputs key).
%% - `tools' (JSON binary): pass through. For `tool_choice =
%%   {named, Name}', filter to just that tool.
%% - `tool_choice' (atom): `auto' | `required' | `none'.
%%   `{named, _}' -> `required' (plus the tools filter above).
%% - `parallel_tool_calls' (atom): `true' | `false'.
-spec build_inputs(#barrel_inference_request{}) -> map().
build_inputs(#barrel_inference_request{
    messages = Messages,
    system = System,
    tools = Tools0,
    tool_choice = ToolChoice0,
    parallel_tool_calls = Parallel
}) ->
    SysMsg =
        case System of
            undefined -> [];
            <<>> -> [];
            S when is_binary(S) -> [#{<<"role">> => <<"system">>, <<"content">> => S}]
        end,
    {Tools, ToolChoiceAtom} = map_tool_choice(Tools0, ToolChoice0),
    MsgsJson = iolist_to_binary(json:encode(SysMsg ++ Messages)),
    ToolsJson = iolist_to_binary(json:encode(safe_list(Tools))),
    #{
        messages => MsgsJson,
        tools => ToolsJson,
        tool_choice => ToolChoiceAtom,
        parallel_tool_calls => bool_atom(Parallel)
    }.

%% =============================================================================
%% Internals
%% =============================================================================

map_tool_choice(Tools, auto) ->
    {Tools, auto};
map_tool_choice(Tools, required) ->
    {Tools, required};
map_tool_choice(_Tools, none) ->
    {[], none};
map_tool_choice(Tools, {named, Name}) ->
    Filtered = [T || T = #{name := N} <- safe_list(Tools), N =:= Name],
    {Filtered, required}.

safe_list(undefined) -> [];
safe_list(L) when is_list(L) -> L.

bool_atom(true) -> true;
bool_atom(_) -> false.

translate(#{name := Name, arguments := Args}, BufBin) ->
    Id = make_tool_id(),
    #{
        id => Id,
        name => Name,
        input => Args,
        full_bin => BufBin
    }.

make_tool_id() ->
    Bin = crypto:strong_rand_bytes(12),
    Hex = list_to_binary(
        [
            io_lib:format("~2.16.0b", [B])
         || <<B>> <= Bin
        ]
    ),
    <<"toolu_", Hex/binary>>.
