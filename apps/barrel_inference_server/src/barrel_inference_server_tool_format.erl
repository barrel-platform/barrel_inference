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

-include("barrel_inference_server.hrl").

-export([lookup/1, parse/2, canonicalise/2]).
-export([native_turn/1, native_render/1, render/3, markers/1, scanner_for/1]).
%% Shared rendering helpers for the per-family render_prompt/2 callbacks.
-export([tool_signatures/1, append_system/2]).

-callback parse(binary()) -> {ok, map()} | {error, term()}.
-callback canonicalise(map()) -> binary().
%% Optional: render the family's native tool system block (with schemas)
%% so the model emits its native tool-call syntax on free decode. A
%% family that implements this opts its models into the no-grammar
%% native path (see native_render/1); the rendered call syntax MUST
%% match the family's `loader.tool_call_markers' or the engine's
%% marker capture won't fire.
-callback render_prompt([tool()], binary() | undefined) -> binary().

-optional_callbacks([render_prompt/2]).

-type spec() :: #{module := module(), _ => _}.

-export_type([spec/0, tool/0]).

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

%% Native free-decode tool path: tools are actually offered (non-empty
%% list, tool_choice = auto) AND the model both emits marker events and
%% its format module implements `render_prompt/2'. {ok, Module} | none.
%% The single source of truth for "skip grammar + render natively +
%% suppress the first-byte heuristic" - used by the pipeline
%% (step_grammar / render_template) and the handlers (grammar_set).
%% Drift between those call sites would be a correctness bug, so the
%% decision lives here.
-spec native_turn(#barrel_inference_request{}) -> {ok, module()} | none.
native_turn(#barrel_inference_request{tools = T, tool_choice = auto, model_id = Id}) when
    is_list(T), T =/= []
->
    native_render(Id);
native_turn(_) ->
    none.

%% Manifest half of native_turn/1: {ok, Module} only when the manifest
%% declares valid `loader.tool_call_markers' (so barrel_inference emits
%% `barrel_inference_tool_call_end' on free decode) AND the resolved
%% format module implements the optional `render_prompt/2' callback.
%% `lookup/1' alone is not enough: it only proves a format is
%% registered, not that markers are set nor that the family renders -
%% a bare-json model with a format but no markers does NOT emit the
%% wire event and must keep the grammar.
-spec native_render(binary()) -> {ok, module()} | none.
native_render(ModelId) when is_binary(ModelId) ->
    case barrel_inference_server_models:get(ModelId) of
        {ok, Manifest} ->
            Loader = maps:get(<<"loader">>, Manifest, #{}),
            Markers = maps:get(<<"tool_call_markers">>, Loader, undefined),
            Format = maps:get(<<"tool_call_format">>, Loader, undefined),
            %% Per-model opt-out: `loader.tool_mode' is a manifest binary
            %% (default <<"native">>). <<"grammar">> forces the grammar
            %% path even on tool_choice=auto - the reliability fallback for
            %% weak local models / strict setups. Any other value -> native.
            case native_mode(Loader) andalso valid_markers(Markers) of
                true -> render_module(Format);
                false -> none
            end;
        {error, _} ->
            none
    end.

native_mode(Loader) ->
    maps:get(<<"tool_mode">>, Loader, <<"native">>) =/= <<"grammar">>.

%% The model's tool-call marker strings (for the streaming text scanner),
%% or `undefined' when not configured / malformed. Same validity shape as
%% valid_markers/1 (start and end are non-empty binaries).
-spec markers(binary()) -> #{start := binary(), 'end' := binary()} | undefined.
markers(ModelId) when is_binary(ModelId) ->
    case barrel_inference_server_models:get(ModelId) of
        {ok, Manifest} ->
            Loader = maps:get(<<"loader">>, Manifest, #{}),
            case maps:get(<<"tool_call_markers">>, Loader, undefined) of
                #{<<"start">> := S, <<"end">> := E} when
                    is_binary(S), is_binary(E), S =/= <<>>, E =/= <<>>
                ->
                    #{start => S, 'end' => E};
                _ ->
                    undefined
            end;
        {error, _} ->
            undefined
    end.

render_module(Format) when is_binary(Format), Format =/= <<>> ->
    case lookup_format(Format) of
        {ok, #{module := Mod}} ->
            case has_render(Mod) of
                true -> {ok, Mod};
                false -> none
            end;
        not_found ->
            none
    end;
render_module(_) ->
    none.

has_render(Mod) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, render_prompt, 2).

%% Mirror barrel_inference_server_loader:maybe_put_tool_call_markers/2: a
%% non-empty map is not enough; start and end must be non-empty
%% binaries or the engine never enables marker capture (and we would
%% skip the grammar with nothing to capture the call).
valid_markers(#{<<"start">> := S, <<"end">> := E}) when
    is_binary(S), is_binary(E), S =/= <<>>, E =/= <<>>
->
    true;
valid_markers(_) ->
    false.

%% Dispatch the native render to the family module. Called by the
%% pipeline with the module native_turn/1 resolved.
-spec render(module(), [tool()], binary() | undefined) -> binary().
render(Mod, Tools, System) ->
    Mod:render_prompt(Tools, System).

%% Config for the handlers' streaming text scanner (barrel_inference_server_tool_scan)
%% on the native path: the resolved render module + the model's marker
%% strings + the request's tool names. `none' off the native path or when
%% markers are missing. Centralised here so the three handlers don't each
%% re-derive it.
-spec scanner_for(#barrel_inference_request{}) ->
    {ok, #{start := binary(), 'end' := binary(), format := module(), tool_names := [binary()]}}
    | none.
scanner_for(#barrel_inference_request{model_id = Id, tools = Tools} = R) ->
    case native_turn(R) of
        {ok, Mod} ->
            case markers(Id) of
                #{start := S, 'end' := E} ->
                    Names = [N || #{name := N} <- tool_list(Tools), is_binary(N)],
                    {ok, #{start => S, 'end' => E, format => Mod, tool_names => Names}};
                undefined ->
                    none
            end;
        none ->
            none
    end.

tool_list(L) when is_list(L) -> L;
tool_list(_) -> [].

%% OpenAI-style function-signature objects, the shape qwen-xml / dsml /
%% mistral list inside their tool blocks. Shared so the per-family
%% render_prompt/2 callbacks don't each rebuild it.
-spec tool_signatures([tool()]) -> [map()].
tool_signatures(Tools) ->
    [
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => N,
                <<"description">> => D,
                <<"parameters">> => S
            }
        }
     || #{name := N, description := D, schema := S} <- Tools
    ].

%% Append a tool block to the system prompt. System is `undefined' for
%% most requests; defined for all three cases so callbacks never crash
%% on undefined or emit a leading separator.
-spec append_system(binary() | undefined, binary()) -> binary().
append_system(undefined, Block) -> Block;
append_system(<<>>, Block) -> Block;
append_system(Sys, Block) when is_binary(Sys) -> <<Sys/binary, "\n\n", Block/binary>>.
