%%% phi4-functools tool-call format. Used by Microsoft Phi-4-mini-instruct
%%% and Phi-4-multimodal-instruct. The wire shape:
%%%
%%%   functools[{"name": "get_weather", "arguments": {"city": "Paris"}},
%%%             {"name": "get_time", "arguments": {}}]
%%%
%%% The literal `functools' / `]' markers are NOT special tokens in the
%%% Phi-4 vocab (the `<|tool|>' / `<|/tool|>' tokens at IDs 200023 / 200024
%%% are used for the SYSTEM-block declaration list, NOT the model output),
%%% so detok preserves the markers. But the close marker `]' is a single
%%% common token, and `barrel_inference_model_llama:map_marker/2' tags
%%% tokens by single-token-id membership - so if we configured a native
%%% `tool_call_markers' pair with end = `]', any nested `]' inside an
%%% argument value (e.g. `"items": [1, 2, 3]') would prematurely close
%%% the span. We therefore use the marker-less post-parse path the
%%% `llama-pythonic' family introduced: at `barrel_inference_done' the
%%% handler runs this family's `parse_all/1' on the accumulated response
%%% buffer with proper bracket-depth tracking (and string-literal
%%% awareness, so a `]' inside a JSON string doesn't count either).
%%%
%%% The body inside `functools[...]' is a JSON array of
%%% `{"name", "arguments"}' objects, so the actual decoding reuses
%%% `json:decode/1' once the outer brackets have been balanced.
%%%
%%% The larger Phi-4 14B model does NOT support tool calling per Microsoft;
%%% only Phi-4-mini-instruct and Phi-4-multimodal-instruct.

-module(barrel_inference_server_tool_format_phi4_functools).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([parse_all/1, post_parse_mode/0]).

-define(START, <<"functools[">>).
-define(SYS_TOOL_OPEN, <<"<|tool|>">>).
-define(SYS_TOOL_CLOSE, <<"<|/tool|>">>).

%% =============================================================================
%% Behaviour callbacks
%% =============================================================================

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    case parse_all(Bin) of
        {ok, [First | _]} -> {ok, First};
        Err -> Err
    end.

-spec parse_all(binary()) -> {ok, [map()]} | {error, term()}.
parse_all(Bin) when is_binary(Bin) ->
    case extract_functools_body(Bin) of
        {ok, Body} ->
            decode_array(<<"[", Body/binary, "]">>);
        error ->
            {error, no_markers}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([
        ?START,
        json:encode(#{<<"name">> => Name, <<"arguments">> => Args}),
        <<"]">>
    ]).

-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    %% Phi-4's chat template renders tool DECLARATIONS in `<|tool|>...
    %% <|/tool|>' around an OpenAI-style JSON array of function schemas
    %% (these markers ARE special tokens in the vocab). The OUTPUT side
    %% uses the literal `functools[...]' shape this family parses.
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = iolist_to_binary([
        ?SYS_TOOL_OPEN,
        json:encode(Sigs),
        ?SYS_TOOL_CLOSE,
        <<"\n\n">>,
        <<"To call a tool, respond with a single JSON array preceded by ">>,
        <<"the literal `functools' prefix and terminated by `]':\n">>,
        <<"functools[{\"name\": <function-name>, \"arguments\": <args-object>}]\n">>
    ]),
    barrel_inference_server_tool_format:append_system(System, Block).

-spec post_parse_mode() -> functools.
post_parse_mode() -> functools.

%% =============================================================================
%% functools[...] extractor (string + bracket-depth aware)
%% =============================================================================

%% Find `functools[' in the buffer (Phi-4 may emit prose before / after on
%% rare runs - the handler hands us the full `buf_text'). When the prefix
%% is present, walk the bytes between the leading `[' and the matching
%% outer `]' with bracket-depth and JSON-string-state tracking. Returns
%% `{ok, Body}' (Body is the substring between the outer brackets,
%% NOT including either bracket) or `error' when the prefix is absent.
extract_functools_body(Bin0) ->
    Bin = string:trim(Bin0),
    case binary:match(Bin, ?START) of
        nomatch ->
            error;
        {Pos, Len} ->
            %% Skip past `functools[' itself - the leading `[' is
            %% counted as depth 1.
            Off = Pos + Len,
            Body = binary:part(Bin, Off, byte_size(Bin) - Off),
            case scan_outer_close(Body, 0, 1, false, false) of
                {ok, EndPos} ->
                    {ok, binary:part(Body, 0, EndPos)};
                unterminated ->
                    %% Pass everything we have; `json:decode/1' will
                    %% reject it as invalid JSON.
                    {ok, Body}
            end
    end.

%% scan_outer_close(Bin, Pos, Depth, InString, Escaped)
%%
%% Depth starts at 1 because the leading `[' has already been consumed
%% (the `functools[' prefix). The walker stops when Depth returns to 0
%% on a `]' that is NOT inside a JSON string and NOT escaped. Returns
%% the byte offset of that closing `]' in the input.
%%
%% Strings are JSON-style (`"..."'). `\\' escapes the next byte.
%% Square brackets `[' / `]' nest; the body may also contain `{' / `}'
%% which don't need depth tracking because we're only matching the
%% outer `]' - a `]' inside an object value can only appear inside a
%% nested JSON array which this depth track handles.
scan_outer_close(<<>>, _Pos, _Depth, _InString, _Escaped) ->
    unterminated;
scan_outer_close(<<_, Rest/binary>>, Pos, Depth, InString, true) ->
    %% Previous char was `\\' - this char is escaped, do not interpret.
    scan_outer_close(Rest, Pos + 1, Depth, InString, false);
scan_outer_close(<<$\\, Rest/binary>>, Pos, Depth, true, _) ->
    scan_outer_close(Rest, Pos + 1, Depth, true, true);
scan_outer_close(<<$", Rest/binary>>, Pos, Depth, InString, false) ->
    scan_outer_close(Rest, Pos + 1, Depth, not InString, false);
scan_outer_close(<<$[, Rest/binary>>, Pos, Depth, false, false) ->
    scan_outer_close(Rest, Pos + 1, Depth + 1, false, false);
scan_outer_close(<<$], _Rest/binary>>, Pos, 1, false, false) ->
    {ok, Pos};
scan_outer_close(<<$], Rest/binary>>, Pos, Depth, false, false) when Depth > 1 ->
    scan_outer_close(Rest, Pos + 1, Depth - 1, false, false);
scan_outer_close(<<_, Rest/binary>>, Pos, Depth, InString, false) ->
    scan_outer_close(Rest, Pos + 1, Depth, InString, false).

%% =============================================================================
%% Array decode
%% =============================================================================

decode_array(JsonBin) ->
    try json:decode(string:trim(JsonBin)) of
        [] ->
            {error, empty_array};
        Items when is_list(Items) ->
            case extract_calls(Items) of
                {ok, _} = Ok -> Ok;
                Err -> Err
            end;
        _ ->
            {error, not_an_array}
    catch
        _:_ -> {error, invalid_json}
    end.

extract_calls(Items) ->
    extract_calls(Items, []).

extract_calls([], Acc) ->
    {ok, lists:reverse(Acc)};
extract_calls([Item | Rest], Acc) ->
    case extract_call(Item) of
        {ok, Call} -> extract_calls(Rest, [Call | Acc]);
        Err -> Err
    end.

extract_call(#{<<"name">> := Name, <<"arguments">> := Args}) when
    is_binary(Name), is_map(Args)
->
    {ok, #{name => Name, arguments => Args}};
extract_call(#{<<"name">> := Name, <<"parameters">> := Args}) when
    is_binary(Name), is_map(Args)
->
    %% Tolerate the OpenAI-style `parameters' key seen on some
    %% fine-tunes (matches the existing `mistral-tool-calls' /
    %% `llama-python-tag' tolerance).
    {ok, #{name => Name, arguments => Args}};
extract_call(#{<<"name">> := Name}) when is_binary(Name) ->
    {ok, #{name => Name, arguments => #{}}};
extract_call(_) ->
    {error, malformed_call}.
