%%% dsml tool-call format. Used by DeepSeek-V3 / DeepSeek-R1 and
%%% derivatives. The format wraps each call between
%%% `<｜tool▁call▁begin｜>' / `<｜tool▁call▁end｜>' (note the
%%% fullwidth U+FF5C and U+2581 chars taken from the model's
%%% special-token vocabulary). Multiple calls are wrapped by the
%%% outer `<｜tool▁calls▁begin｜>' / `<｜tool▁calls▁end｜>' batch
%%% markers.
%%%
%%% Per-call body (single):
%%%
%%%   <｜tool▁call▁begin｜>function<｜tool▁sep｜>NAME
%%%   ```json
%%%   {"arg":"val"}
%%%   ```<｜tool▁call▁end｜>
%%%
%%% The parser tolerates:
%%%   - presence or absence of the outer `<｜tool▁calls▁begin｜>` /
%%%     `<｜tool▁calls▁end｜>` batch wrapper inside FullBin
%%%   - presence or absence of the leading `function<｜tool▁sep｜>'
%%%     type prefix
%%%   - presence or absence of the ```json ... ``` fence around the
%%%     arguments JSON
%%%   - leading / trailing whitespace at any boundary
%%%
%%% Spec source: the public DeepSeek-V3 chat template (tokenizer_config.json).
%%% Runtime verification against a real DeepSeek backend is recommended
%%% before relying on the canonicaliser for byte-exact replay.

-module(barrel_inference_server_tool_format_dsml).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([family_name/0, detect/1]).

family_name() -> <<"dsml">>.

%% DeepSeek-V3 lineage: the `<｜tool▁call▁begin｜>' marker is
%% globally unique to this family (no other open-weights model uses
%% the same FULLWIDTH BAR + KOREAN angle-bracket framing).
-spec detect(binary()) ->
    {detected, #{start := binary(), 'end' := binary()}} | not_detected.
detect(T) when is_binary(T) ->
    case binary:match(T, <<"<｜tool▁call▁begin｜>"/utf8>>) of
        nomatch ->
            not_detected;
        _ ->
            {detected, #{
                start => <<"<｜tool▁call▁begin｜>"/utf8>>,
                'end' => <<"<｜tool▁call▁end｜>"/utf8>>
            }}
    end.

-define(CALLS_BEGIN, <<"<｜tool▁calls▁begin｜>"/utf8>>).
-define(CALLS_END, <<"<｜tool▁calls▁end｜>"/utf8>>).
-define(CALL_BEGIN, <<"<｜tool▁call▁begin｜>"/utf8>>).
-define(CALL_END, <<"<｜tool▁call▁end｜>"/utf8>>).
-define(SEP, <<"<｜tool▁sep｜>"/utf8>>).
-define(FENCE_OPEN, <<"```json">>).
-define(FENCE_CLOSE, <<"```">>).

%% Native tool system block matching the DeepSeek-V3 chat template:
%% function signatures, then the exact call envelope built from the
%% same special-token markers the engine captures.
-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = [
        <<"## Tools\n\n">>,
        <<"You have access to the following tools. Their function signatures are:\n">>,
        [[json:encode(S), <<"\n">>] || S <- Sigs],
        <<"\nWhen you call a tool, emit it in exactly this format:\n">>,
        ?CALLS_BEGIN,
        ?CALL_BEGIN,
        <<"function">>,
        ?SEP,
        <<"<function-name>\n">>,
        ?FENCE_OPEN,
        <<"\n<args-json-object>\n">>,
        ?FENCE_CLOSE,
        ?CALL_END,
        ?CALLS_END
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Stripped = strip_outer(string:trim(Bin)),
    Inner = strip_call_markers(Stripped),
    decode_call_body(string:trim(Inner)).

strip_outer(Bin) ->
    case binary:split(Bin, ?CALLS_BEGIN) of
        [_, AfterBegin] ->
            case binary:split(AfterBegin, ?CALLS_END) of
                [Inside, _] -> string:trim(Inside);
                _ -> AfterBegin
            end;
        _ ->
            Bin
    end.

strip_call_markers(Bin) ->
    Stage1 =
        case binary:split(Bin, ?CALL_BEGIN) of
            [_, A] -> A;
            _ -> Bin
        end,
    case binary:split(Stage1, ?CALL_END) of
        [B, _] -> B;
        _ -> Stage1
    end.

decode_call_body(Body) ->
    case binary:split(Body, ?SEP) of
        [_, R] ->
            %% Canonical: `function<｜tool▁sep｜>NAME\n...' with the sep
            %% present. Drop the type prefix and parse the rest.
            extract_name_and_args(string:trim(R));
        _ ->
            %% Tolerance for the marker-stripped real-backend shape: the
            %% NIF detokenizer's `special=false' drops `<｜tool▁sep｜>'
            %% from the captured FullBin, leaving the literal `function'
            %% type-prefix text fused to the name (`functionNAME\n...').
            %% Strip the leading `function' text when present.
            %%
            %% Trade-off: a user-defined function whose name LITERALLY
            %% starts with `function' (e.g. `functionGetData') is
            %% indistinguishable on the wire from the canonical
            %% `function<sep>GetData' shape with markers stripped, and
            %% loses its prefix. DeepSeek's canonical tool-call wire
            %% protocol reserves the literal `function' as a type
            %% prefix, so real tool definitions should not start with
            %% it; the trade-off favours the common case.
            Rest =
                case Body of
                    <<"function", R2/binary>> -> R2;
                    _ -> Body
                end,
            extract_name_and_args(string:trim(Rest))
    end.

extract_name_and_args(<<>>) ->
    {error, empty_body};
extract_name_and_args(Body) ->
    case binary:split(Body, <<"\n">>) of
        [NameLine, AfterName] ->
            Name = string:trim(NameLine),
            decode_args_section(Name, string:trim(AfterName));
        _ ->
            {error, no_separator}
    end.

decode_args_section(_, <<>>) ->
    {error, no_arguments};
decode_args_section(Name, Section) ->
    JsonBin = strip_fence(Section),
    case decode_json(JsonBin) of
        {ok, Args} when is_binary(Name), Name =/= <<>> ->
            {ok, #{name => Name, arguments => Args}};
        {ok, _} ->
            {error, empty_name};
        {error, _} = E ->
            E
    end.

strip_fence(Bin) ->
    case binary:split(Bin, ?FENCE_OPEN) of
        [_, AfterOpen] ->
            case binary:split(string:trim(AfterOpen), ?FENCE_CLOSE) of
                [Inside, _] -> string:trim(Inside);
                _ -> string:trim(AfterOpen)
            end;
        _ ->
            Bin
    end.

decode_json(Bin) ->
    try json:decode(Bin) of
        M when is_map(M) -> {ok, M};
        _ -> {error, malformed_arguments}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([
        ?CALL_BEGIN,
        <<"function">>,
        ?SEP,
        Name,
        <<"\n```json\n">>,
        json:encode(Args),
        <<"\n```">>,
        ?CALL_END
    ]).
