%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_autoparser).
-moduledoc """
Shared handler-side autoparser bridge.

Each of `barrel_inference_server_h_chat', `barrel_inference_server_h_messages',
and `barrel_inference_server_h_responses' calls
`maybe_extract/4' on `barrel_inference_done' when no tool calls were
captured by the engine's marker path. The helper rebuilds (or fetches
from cache) a chat params_ref for `(Model, ToolsHash)' and parses the
buffered response text via llama.cpp's autoparser.

When the parser returns at least one tool_call, the helper translates
each to the handler's captured-call shape
(`#{id, name, input, full_bin}'); when it returns none, the helper
returns `none' so the handler dispatches its existing
text-only path.

This is the fall-back path: models whose manifest carries
`tool_call_markers' continue to capture via the engine's
per-token marker scanner. The autoparser only fires when that
yields nothing.
""".

-include_lib("barrel_inference_server/include/barrel_inference_server.hrl").

-export([maybe_extract/4]).

-export_type([captured_call/0]).

-type captured_call() :: #{
    id := binary(),
    name := binary(),
    input := map(),
    full_bin := binary()
}.

%% Attempt to extract tool calls from BufText for (Model, Request).
%% Returns `{ok, [Call]}' on a non-empty extraction, `none'
%% otherwise (no tools requested, no model_ref support, parser
%% returned no tool calls, or any error).
-spec maybe_extract(
    Model :: binary(),
    Request :: #barrel_inference_request{},
    BufText :: iodata(),
    ApiHint :: openai | anthropic
) ->
    {ok, [captured_call()]} | none.
maybe_extract(_Model, #barrel_inference_request{tools = undefined}, _BufText, _Api) ->
    none;
maybe_extract(_Model, #barrel_inference_request{tools = []}, _BufText, _Api) ->
    none;
maybe_extract(
    Model,
    #barrel_inference_request{tools = Tools, messages = Messages, system = System},
    BufText,
    _Api
) ->
    BufBin = iolist_to_binary(BufText),
    Inputs = build_inputs(Messages, System, Tools),
    ToolsHash = tools_hash(Tools),
    case barrel_inference:chat_apply(Model, ToolsHash, Inputs) of
        {ok, Params, _Prompt} ->
            case barrel_inference:chat_parse(Params, BufBin, false) of
                {ok, #{tool_calls := [_ | _] = Calls}} ->
                    {ok, [translate(C, BufBin) || C <- Calls]};
                _ ->
                    none
            end;
        _ ->
            none
    end.

%% =============================================================================
%% Internals
%% =============================================================================

build_inputs(Messages, System, Tools) ->
    SysMsg =
        case System of
            undefined -> [];
            <<>> -> [];
            S when is_binary(S) -> [#{<<"role">> => <<"system">>, <<"content">> => S}]
        end,
    %% `messages' on `#barrel_inference_request{}' is always a list
    %% (possibly empty); the type spec forbids `undefined' here.
    UserMsgs = Messages,
    MsgsJson = iolist_to_binary(json:encode(SysMsg ++ UserMsgs)),
    ToolsJson = iolist_to_binary(json:encode(Tools)),
    #{
        messages => MsgsJson,
        tools => ToolsJson
    }.

tools_hash(Tools) ->
    crypto:hash(sha256, iolist_to_binary(json:encode(Tools))).

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
