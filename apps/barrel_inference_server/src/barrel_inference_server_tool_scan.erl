%%% Streaming tool-call text scanner (Ollama-style). On the native
%%% `tool_mode' path the model free-decodes and emits its tool calls as
%%% TEXT (the engine's single-token marker capture does not fire when the
%%% model writes `<tool_call>` / `<json>` / bare JSON as ordinary tokens).
%%% This module separates content from tool calls over the streamed text:
%%%
%%%   feed(State, TextChunk) -> {[ {text,Bin} | {tool,Call} ], State}
%%%   finish(State)          -> {[Emit], State}   (flush the tail as text)
%%%
%%% It is tolerant: it recognises the model's configured start/end markers
%%% (parsed by the family `parse/1'), a single generic `<tag>...</tag>'
%%% wrapper around JSON, and bare JSON objects. A candidate is only a tool
%%% call when its `name' is one the request actually offered (`tool_names')
%%% and its arguments are an object - this is what stops a legit JSON
%%% answer being mis-captured and what makes `<json>{...}</json>` work.
%%% Strict schema enforcement (types/enums/required) is NOT done here - use
%%% `tool_mode=grammar' / `tool_choice=required' for that.
%%%
%%% Bounded: text mode holds back at most ?MAX_HOLD bytes (a possible
%%% split marker); a forming region is capped at ?MAX_REGION bytes, beyond
%%% which it is flushed as text. So prose/code that merely looks like a
%%% partial tool call can neither stall streaming nor grow memory.
%%%
%%% Pure module: no barrel_inference, no cowboy, no I/O.

-module(barrel_inference_server_tool_scan).

-export([new/1, feed/2, finish/1]).

-define(MAX_HOLD, 64).
-define(MAX_REGION, 16384).

-record(st, {
    start :: binary(),
    stop :: binary(),
    format :: module(),
    names :: #{binary() => true},
    buf = <<>> :: binary()
}).

-type call() :: #{name := binary(), arguments := map(), raw := binary()}.
-type emit() :: {text, binary()} | {tool, call()}.
-opaque state() :: #st{}.

-export_type([state/0, call/0, emit/0]).

-spec new(#{
    start := binary(),
    'end' := binary(),
    format := module(),
    tool_names := [binary()]
}) -> state().
new(#{start := S, 'end' := E, format := Mod, tool_names := Names}) ->
    #st{
        start = S,
        stop = E,
        format = Mod,
        names = maps:from_list([{N, true} || N <- Names, is_binary(N)])
    }.

-spec feed(state(), binary()) -> {[emit()], state()}.
feed(St = #st{buf = B}, Text) when is_binary(Text) ->
    {Rev, St1} = loop(St#st{buf = <<B/binary, Text/binary>>}, [], false),
    {lists:reverse(Rev), St1}.

%% Flush: resolve the held buffer treating it as final (so a region whose
%% closing marker never arrived still parses), then anything left is text.
-spec finish(state()) -> {[emit()], state()}.
finish(St) ->
    {Rev, St1} = loop(St, [], true),
    case St1#st.buf of
        <<>> -> {lists:reverse(Rev), St1};
        Rest -> {lists:reverse([{text, Rest} | Rev]), St1#st{buf = <<>>}}
    end.

%%====================================================================
%% Scan loop
%%====================================================================

%% Consume St.buf as far as possible, accumulating emits (reversed) and
%% leaving an unresolved tail in St.buf. `Final' is true on finish/1, when
%% a region whose closing marker never arrived is parsed anyway.
loop(St = #st{buf = Buf}, Rev, Final) ->
    case region_start(Buf, St) of
        none ->
            %% No region indicator: emit safe text, hold a possible split
            %% marker tail.
            {Safe, Hold} = split_hold(Buf, St),
            {push_text(Safe, Rev), St#st{buf = Hold}};
        {hold, RS} ->
            %% A start marker is present but its JSON `{' has not arrived
            %% yet: emit text before the marker, hold the marker onward so
            %% it is never streamed as content. Bounded by ?MAX_REGION.
            hold_region(Buf, RS, Rev, St);
        {RS, JsonStart, Kind} ->
            handle_region(Buf, RS, JsonStart, Kind, Rev, St, Final)
    end.

%% A JSON object start was found at JsonStart (region begins at RS). Hold
%% while the object is incomplete, or while a marker region's closing
%% marker hasn't arrived; otherwise emit it.
handle_region(Buf, RS, JsonStart, Kind, Rev, St, Final) ->
    case balanced(Buf, JsonStart) of
        incomplete ->
            hold_region(Buf, RS, Rev, St);
        JsonEnd ->
            RegionEnd = consume_end(Buf, JsonEnd, Kind, St),
            case settled(Kind, RS, JsonStart, JsonEnd, RegionEnd, St, Final) of
                false -> hold_region(Buf, RS, Rev, St);
                true -> emit_region(Buf, RS, JsonStart, JsonEnd, RegionEnd, Kind, Rev, St, Final)
            end
    end.

emit_region(Buf, RS, JsonStart, JsonEnd, RegionEnd, Kind, Rev, St, Final) ->
    Region = binary:part(Buf, RS, RegionEnd - RS),
    Json = binary:part(Buf, JsonStart, JsonEnd - JsonStart),
    case classify(Kind, Region, Json, St) of
        {tool, Call} ->
            Rev1 = [{tool, Call} | push_text(binary:part(Buf, 0, RS), Rev)],
            loop(St#st{buf = suffix_from(Buf, RegionEnd)}, Rev1, Final);
        not_tool ->
            %% Not a tool call: this JSON is content. Emit up to its close
            %% and keep scanning the remainder.
            Upto = binary:part(Buf, 0, JsonEnd),
            loop(St#st{buf = suffix_from(Buf, JsonEnd)}, push_text(Upto, Rev), Final)
    end.

%% Hold from RS (emit text before it), bounded: a runaway candidate is
%% flushed as text rather than buffered without limit.
hold_region(Buf, RS, Rev, St) ->
    Held = suffix_from(Buf, RS),
    case byte_size(Held) > ?MAX_REGION of
        true -> {push_text(Buf, Rev), St#st{buf = <<>>}};
        false -> {push_text(binary:part(Buf, 0, RS), Rev), St#st{buf = Held}}
    end.

%% Is the region complete enough to parse? A marker region needs its end
%% marker consumed (unless the format has none, or we are flushing); a
%% wrapped bare region needs its closing tag; a plain bare object is
%% settled as soon as its braces balance.
settled(_Kind, _RS, _JsonStart, _JsonEnd, _RegionEnd, _St, true) ->
    true;
settled(marker, _RS, _JsonStart, JsonEnd, RegionEnd, #st{stop = Stop}, false) ->
    RegionEnd > JsonEnd orelse Stop =:= <<>>;
settled(bare, RS, JsonStart, _JsonEnd, _RegionEnd, _St, false) when RS =:= JsonStart ->
    true;
settled(bare, _RS, _JsonStart, JsonEnd, RegionEnd, _St, false) ->
    RegionEnd > JsonEnd.

%% Earliest region indicator in Buf: the configured start marker, a
%% generic `<tag>'/`[tag]' wrapper-open immediately before a `{`, or a bare
%% `{'. Returns {RegionStart, JsonStart, Kind} | none, where Kind is
%% `marker' (parse via the family module on the whole region) or `bare'
%% (strip an optional single wrapper, parse inner JSON).
region_start(Buf, #st{start = Start}) ->
    Sm = first_index(Buf, Start),
    Bm = first_index(Buf, <<"{">>),
    case {Sm, Bm} of
        {none, none} ->
            none;
        {M, B} when is_integer(M) andalso (B =:= none orelse M =< B) ->
            %% configured marker first; JSON object begins at the next `{'.
            %% If the `{' has not streamed in yet, hold from the marker.
            case first_index_from(Buf, <<"{">>, M) of
                none -> {hold, M};
                J -> {M, J, marker}
            end;
        {_, B} when is_integer(B) ->
            %% bare `{' (no earlier configured marker): include an adjacent
            %% single wrapper-open in the region so it is not leaked as text
            {wrapper_start(Buf, B), B, bare}
    end.

%% Walk back from the `{' over whitespace and a single `<...>'/`[...]'
%% wrapper-open, returning the region start index.
wrapper_start(Buf, J) ->
    P = rstrip_ws(Buf, J),
    case P > 0 andalso lists:member(binary:at(Buf, P - 1), [$>, $]]) of
        true ->
            Open =
                case binary:at(Buf, P - 1) of
                    $> -> $<;
                    $] -> $[
                end,
            case rfind(Buf, Open, P - 1) of
                none ->
                    J;
                OpenIdx ->
                    %% only treat as a wrapper if it is a short tag (no `{'
                    %% inside it), else it is just text
                    Tag = binary:part(Buf, OpenIdx, P - OpenIdx),
                    case binary:match(Tag, <<"{">>) of
                        nomatch -> OpenIdx;
                        _ -> J
                    end
            end;
        false ->
            J
    end.

%% Index just past the end of the region: for a marker region, past the
%% configured end marker if it directly follows (allowing ws); otherwise
%% the JSON end. For bare, past a closing `</...>'/`]' wrapper if present.
consume_end(Buf, JsonEnd, marker, #st{stop = Stop}) when Stop =/= <<>> ->
    skip_marker(Buf, JsonEnd, Stop);
consume_end(Buf, JsonEnd, _Kind, _St) ->
    skip_wrapper_close(Buf, JsonEnd).

classify(marker, Region, Json, St = #st{format = Mod}) ->
    %% Prefer the family parser (exact format, e.g. mistral arrays); fall
    %% back to decoding the inner JSON object directly so a region still
    %% parses when its closing marker is absent (flush) or the family
    %% parser is strict.
    case safe_parse(Mod, Region) of
        {ok, Name, Args} -> accept(Name, Args, Region, St);
        error -> classify(bare, Region, Json, St)
    end;
classify(bare, Region, Json, St) ->
    case decode_bare(Json) of
        {ok, Name, Args} -> accept(Name, Args, Region, St);
        error -> not_tool
    end.

accept(Name, Args, Region, #st{names = Names}) when is_map(Args) ->
    case maps:is_key(Name, Names) of
        true -> {tool, #{name => Name, arguments => Args, raw => Region}};
        false -> not_tool
    end;
accept(_Name, _Args, _Region, _St) ->
    not_tool.

%%====================================================================
%% Parsing
%%====================================================================

%% Dispatch through the behaviour module's parse/2 (it owns the dynamic
%% call to the family `parse/1'); keeps this module free of dynamic calls.
safe_parse(Mod, Region) ->
    try barrel_inference_server_tool_format:parse(#{module => Mod}, Region) of
        {ok, #{name := Name, arguments := Args}} when is_binary(Name) -> {ok, Name, Args};
        _ -> error
    catch
        _:_ -> error
    end.

decode_bare(Json) ->
    try json:decode(Json) of
        #{<<"name">> := Name, <<"arguments">> := Args} when is_binary(Name) -> {ok, Name, Args};
        #{<<"name">> := Name, <<"parameters">> := Args} when is_binary(Name) -> {ok, Name, Args};
        _ -> error
    catch
        _:_ -> error
    end.

%%====================================================================
%% Byte helpers
%%====================================================================

first_index(_Buf, <<>>) ->
    none;
first_index(Buf, Pat) ->
    case binary:match(Buf, Pat) of
        {I, _} -> I;
        nomatch -> none
    end.

first_index_from(Buf, Pat, From) ->
    Len = byte_size(Buf) - From,
    case Len =< 0 of
        true ->
            none;
        false ->
            case binary:match(binary:part(Buf, From, Len), Pat) of
                {I, _} -> From + I;
                nomatch -> none
            end
    end.

rfind(_Buf, _Ch, 0) ->
    none;
rfind(Buf, Ch, Hi) ->
    case binary:at(Buf, Hi - 1) of
        Ch -> Hi - 1;
        _ -> rfind(Buf, Ch, Hi - 1)
    end.

rstrip_ws(_Buf, 0) ->
    0;
rstrip_ws(Buf, P) ->
    case lists:member(binary:at(Buf, P - 1), [$\s, $\t, $\n, $\r]) of
        true -> rstrip_ws(Buf, P - 1);
        false -> P
    end.

suffix_from(Buf, From) ->
    binary:part(Buf, From, byte_size(Buf) - From).

%% Scan a JSON value starting at `Start' (must be `{'); return the index
%% just past the matching close brace, or `incomplete'. Respects strings
%% and escapes.
balanced(Buf, Start) ->
    balanced(Buf, Start, byte_size(Buf), 0, false, false).

balanced(_Buf, I, Len, _Depth, _InStr, _Esc) when I >= Len ->
    incomplete;
balanced(Buf, I, Len, Depth, true, true) ->
    balanced(Buf, I + 1, Len, Depth, true, false);
balanced(Buf, I, Len, Depth, true, false) ->
    case binary:at(Buf, I) of
        $\\ -> balanced(Buf, I + 1, Len, Depth, true, true);
        $" -> balanced(Buf, I + 1, Len, Depth, false, false);
        _ -> balanced(Buf, I + 1, Len, Depth, true, false)
    end;
balanced(Buf, I, Len, Depth, false, _Esc) ->
    case binary:at(Buf, I) of
        $" -> balanced(Buf, I + 1, Len, Depth, true, false);
        ${ -> balanced(Buf, I + 1, Len, Depth + 1, false, false);
        $} when Depth =< 1 -> I + 1;
        $} -> balanced(Buf, I + 1, Len, Depth - 1, false, false);
        _ -> balanced(Buf, I + 1, Len, Depth, false, false)
    end.

%% Past the stop marker if it directly follows JsonEnd (allowing ws);
%% else JsonEnd unchanged.
skip_marker(Buf, JsonEnd, Stop) ->
    P = lstrip_ws(Buf, JsonEnd),
    case prefix_at(Buf, P, Stop) of
        true -> P + byte_size(Stop);
        false -> JsonEnd
    end.

%% Past a single `</...>'/`]' wrapper close if it directly follows.
skip_wrapper_close(Buf, JsonEnd) ->
    P = lstrip_ws(Buf, JsonEnd),
    Len = byte_size(Buf),
    case P < Len andalso lists:member(binary:at(Buf, P), [$<, $]]) of
        false ->
            JsonEnd;
        true ->
            case binary:at(Buf, P) of
                $] -> P + 1;
                $< -> close_tag_end(Buf, P, Len)
            end
    end.

close_tag_end(Buf, P, _Len) ->
    case first_index_from(Buf, <<">">>, P) of
        none -> P;
        Gt -> Gt + 1
    end.

lstrip_ws(Buf, P) ->
    Len = byte_size(Buf),
    case P < Len andalso lists:member(binary:at(Buf, P), [$\s, $\t, $\n, $\r]) of
        true -> lstrip_ws(Buf, P + 1);
        false -> P
    end.

prefix_at(Buf, P, Pat) ->
    PL = byte_size(Pat),
    byte_size(Buf) - P >= PL andalso binary:part(Buf, P, PL) =:= Pat.

%% No region indicator present: emit the safe prefix as text, hold a
%% bounded tail that could be the start of a split marker (a proper prefix
%% of the configured start, or an unclosed `<'/`[' run).
split_hold(Buf, #st{start = Start}) ->
    HoldLen = hold_len(Buf, Start),
    Keep = min(HoldLen, ?MAX_HOLD),
    N = byte_size(Buf),
    {binary:part(Buf, 0, N - Keep), binary:part(Buf, N - Keep, Keep)}.

hold_len(Buf, Start) ->
    N = byte_size(Buf),
    %% longest suffix of Buf that is a (proper) prefix of Start
    P = longest_start_prefix(Buf, Start, min(N, byte_size(Start) - 1)),
    %% or a trailing unclosed `<...'/`[...' run (a possible wrapper/marker)
    W = trailing_open_run(Buf, N),
    max(P, W).

longest_start_prefix(_Buf, _Start, 0) ->
    0;
longest_start_prefix(Buf, Start, K) ->
    N = byte_size(Buf),
    case binary:part(Buf, N - K, K) =:= binary:part(Start, 0, K) of
        true -> K;
        false -> longest_start_prefix(Buf, Start, K - 1)
    end.

trailing_open_run(Buf, N) ->
    case rfind_any(Buf, [$<, $[], N) of
        none ->
            0;
        Idx ->
            %% only hold if the run has no `>'/`]' after it (still open)
            Tail = binary:part(Buf, Idx, N - Idx),
            case binary:match(Tail, [<<">">>, <<"]">>]) of
                nomatch -> byte_size(Tail);
                _ -> 0
            end
    end.

rfind_any(_Buf, _Chs, 0) ->
    none;
rfind_any(Buf, Chs, Hi) ->
    case lists:member(binary:at(Buf, Hi - 1), Chs) of
        true -> Hi - 1;
        false -> rfind_any(Buf, Chs, Hi - 1)
    end.

push_text(<<>>, Rev) -> Rev;
push_text(Bin, Rev) -> [{text, Bin} | Rev].
