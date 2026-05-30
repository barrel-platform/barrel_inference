%%% glm45 tool-call format. Used by zai-org / THUDM GLM-4.5, GLM-4.5-Air,
%%% and GLM-4.6 (wire-identical across the three; same tokenizer IDs,
%%% same chat template emission block). The wire shape:
%%%
%%%   <tool_call>get_weather
%%%   <arg_key>city</arg_key>
%%%   <arg_value>Paris</arg_value>
%%%   <arg_key>units</arg_key>
%%%   <arg_value>metric</arg_value>
%%%   </tool_call>
%%%
%%% The function name lives on the same line as `<tool_call>', then a
%%% newline, then alternating `<arg_key>...</arg_key>' /
%%% `<arg_value>...</arg_value>' pairs.
%%%
%%% The eight tool / arg markers (`<tool_call>', `</tool_call>',
%%% `<tool_response>', `</tool_response>', `<arg_key>', `</arg_key>',
%%% `<arg_value>', `</arg_value>') are SINGLE tokens in the GLM-4.x
%%% tokenizer (IDs 151352 - 151359, `special:false'), so the engine's
%%% native marker capture path (qwen3-coder lineage) handles this
%%% format unchanged: the engine emits `barrel_inference_tool_call_end'
%%% with `FullBin' containing the bytes between `<tool_call>' and
%%% `</tool_call>', and `parse/1' pulls out the name and args.
%%%
%%% Parameter values are stringly-typed in this format (the template
%%% renders non-string values via `tojson(ensure_ascii=False)' but
%%% renders bare strings without quoting), so on parse each value is
%%% JSON-decoded when it round-trips as JSON (numbers, booleans,
%%% objects, arrays, quoted strings) and kept as a raw binary
%%% otherwise (bare strings like `Paris').
%%%
%%% GLM-4.7 changes the first-line layout - vLLM ships a separate
%%% `glm47_moe' parser. This family is `4.5 / 4.5-Air / 4.6' only.

-module(barrel_inference_server_tool_format_glm45).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([family_name/0, detect/1]).

-define(START, <<"<tool_call>">>).
-define(END, <<"</tool_call>">>).

family_name() -> <<"glm45">>.

%% GLM-4.5 / 4.5-Air / 4.6 share the `<tool_call>' marker with
%% qwen-xml and qwen3-coder but emit `<arg_key>' / `<arg_value>'
%% pairs for arguments; the disambiguator is `<arg_key>'.
-spec detect(binary()) ->
    {detected, #{start := binary(), 'end' := binary()}} | not_detected.
detect(T) when is_binary(T) ->
    case
        binary:match(T, ?START) =/= nomatch andalso
            binary:match(T, <<"<arg_key>">>) =/= nomatch
    of
        true -> {detected, #{start => ?START, 'end' => ?END}};
        false -> not_detected
    end.

%% =============================================================================
%% parse
%% =============================================================================

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Body = strip_markers(Bin),
    case split_name_and_args(Body) of
        {ok, Name, ArgsBody} ->
            {ok, #{name => Name, arguments => parse_args(ArgsBody)}};
        Err ->
            Err
    end.

%% Drop the outer call markers if present; otherwise parse the raw body.
strip_markers(Bin) ->
    AfterStart =
        case binary:split(Bin, ?START) of
            [_, A] -> A;
            _ -> Bin
        end,
    case binary:split(AfterStart, ?END) of
        [B, _] -> B;
        _ -> AfterStart
    end.

%% The body comes in as `NAME\nRest' (markers already stripped by
%% `strip_markers/1'). We split on the first newline WITHOUT a
%% prior trim - a leading newline (empty first line) means the
%% model emitted `<tool_call>\n<arg_key>...' with no name, which is
%% malformed. The captured name token is itself trimmed of
%% surrounding whitespace (e.g. the leading space in `<tool_call> f\n').
split_name_and_args(Body) ->
    case binary:split(Body, <<"\n">>) of
        [NameLine] ->
            case string:trim(NameLine) of
                <<>> -> {error, no_name};
                Name -> {ok, Name, <<>>}
            end;
        [NameLine, Rest] ->
            case string:trim(NameLine) of
                <<>> -> {error, no_name};
                Name -> {ok, Name, Rest}
            end
    end.

parse_args(<<>>) ->
    #{};
parse_args(Body) ->
    case
        re:run(
            Body,
            "<arg_key>(.*?)</arg_key>\\s*<arg_value>(.*?)</arg_value>",
            [dotall, global, {capture, [1, 2], binary}]
        )
    of
        {match, Pairs} ->
            maps:from_list([{string:trim(K), coerce(string:trim(V))} || [K, V] <- Pairs]);
        nomatch ->
            #{}
    end.

%% Recover a typed value from the stringly-typed `<arg_value>' body:
%% decode as JSON when it parses (int / bool / object / array / quoted
%% string), keep the raw binary otherwise (bare unquoted strings are
%% not valid JSON).
coerce(V) ->
    try json:decode(V) of
        Decoded -> Decoded
    catch
        _:_ -> V
    end.

%% =============================================================================
%% canonicalise (re-render a tool_use from history into the native shape)
%% =============================================================================

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when is_binary(Name), is_map(Args) ->
    Pairs = [render_pair(K, V) || {K, V} <- maps:to_list(Args)],
    iolist_to_binary([
        ?START,
        Name,
        <<"\n">>,
        Pairs,
        ?END
    ]).

render_pair(K, V) ->
    [
        <<"<arg_key>">>,
        K,
        <<"</arg_key>\n">>,
        <<"<arg_value>">>,
        render_value(V),
        <<"</arg_value>\n">>
    ].

render_value(V) when is_binary(V) -> V;
render_value(V) -> json:encode(V).

%% =============================================================================
%% render_prompt (native tool system block, GLM-4.x shape)
%% =============================================================================

-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    SigLines = [[json:encode(S), <<"\n">>] || S <- Sigs],
    Block = iolist_to_binary([
        <<"# Tools\n\n">>,
        <<"You may call one or more functions to assist with the user query.\n\n">>,
        <<"You are provided with function signatures within ">>,
        <<"<tools></tools> XML tags:\n<tools>\n">>,
        SigLines,
        <<"</tools>\n\n">>,
        <<"For each function call, output the function name and arguments ">>,
        <<"within the following XML format:\n">>,
        ?START,
        <<"{function-name}\n">>,
        <<"<arg_key>{arg-key-1}</arg_key>\n">>,
        <<"<arg_value>{arg-value-1}</arg_value>\n">>,
        <<"...\n">>,
        ?END,
        <<"\n">>
    ]),
    barrel_inference_server_tool_format:append_system(System, Block).
