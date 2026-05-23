%%% Per-model tool-call format registry. Each model family that emits
%%% tool calls in its own on-wire shape (qwen-xml, dsml, llama
%%% python-tag, etc.) gets one module implementing the
%%% `barrel_inference_server_tool_format' behaviour. The registry resolves a
%%% canonical model id to its format spec via the manifest's
%%% `loader.tool_call_format' field and the `tool_call_formats' app
%%% env. PR 5's capture path calls `parse/2' on the raw `FullBin'
%%% delivered by barrel_inference 0.5; PR 6's render path calls
%%% `canonicalise/2' when a tool_use block from history has no
%%% replay-map entry.

-module(barrel_inference_server_tool_format).

-export([lookup/1, parse/2, canonicalise/2]).

-callback parse(binary()) -> {ok, map()} | {error, term()}.
-callback canonicalise(map()) -> binary().

-type spec() :: #{module := module(), _ => _}.

-export_type([spec/0]).

%% Resolve a canonical model id to its format spec. Reads the
%% manifest's `loader.tool_call_format' binary key, then looks the
%% name up in `barrel_inference_server_config:tool_call_formats/0'. Returns
%% `not_found' when either lookup fails - callers fall back to the
%% legacy `mode = tool_buffer' accumulator.
-spec lookup(binary()) -> {ok, spec()} | not_found.
lookup(ModelId) when is_binary(ModelId) ->
    case barrel_inference_server_models:get(ModelId) of
        {ok, Manifest} ->
            Loader = maps:get(<<"loader">>, Manifest, #{}),
            case maps:get(<<"tool_call_format">>, Loader, undefined) of
                FormatName when is_binary(FormatName), FormatName =/= <<>> ->
                    lookup_format(FormatName);
                _ ->
                    not_found
            end;
        {error, _} ->
            not_found
    end.

lookup_format(FormatName) ->
    Formats = barrel_inference_server_config:tool_call_formats(),
    case maps:get(FormatName, Formats, undefined) of
        #{module := Mod} = Spec when is_atom(Mod) ->
            {ok, Spec};
        _ ->
            not_found
    end.

%% Dispatch the parse to the format module.
-spec parse(spec(), binary()) -> {ok, map()} | {error, term()}.
parse(#{module := Mod}, Bin) when is_binary(Bin) ->
    Mod:parse(Bin).

%% Dispatch the canonicalise to the format module.
-spec canonicalise(spec(), map()) -> binary().
canonicalise(#{module := Mod}, Json) when is_map(Json) ->
    Mod:canonicalise(Json).
