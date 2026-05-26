%%% qwen3-coder tool-call format. Qwen3-Coder (qwen3moe) was trained on a
%%% nested-XML tool-call shape, NOT the Qwen2.5 JSON-in-tags shape that the
%%% `qwen-xml' family uses. A call is emitted between the same
%%% `<tool_call>...</tool_call>' markers, but the body is:
%%%
%%%   <tool_call>
%%%   <function=NAME>
%%%   <parameter=P1>
%%%   value 1
%%%   </parameter>
%%%   <parameter=P2>
%%%   value 2 (may span lines)
%%%   </parameter>
%%%   </function>
%%%   </tool_call>
%%%
%%% Parameter values are stringly-typed in this format (the template
%%% stringifies everything between the `<parameter=...>' tags), so on
%%% parse each value is JSON-decoded when it round-trips as JSON
%%% (numbers / booleans / objects / arrays / quoted strings) and kept as
%%% a raw binary otherwise (bare strings like `lk-monitor-southeast-ph').

-module(barrel_inference_server_tool_format_qwen3_coder).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).

-define(START, <<"<tool_call>">>).
-define(END, <<"</tool_call>">>).

%% =============================================================================
%% parse
%% =============================================================================

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Body = strip_markers(Bin),
    case re:run(Body, "<function=([^>]*)>", [{capture, [1], binary}]) of
        {match, [Name]} ->
            {ok, #{name => string:trim(Name), arguments => parse_parameters(Body)}};
        nomatch ->
            {error, no_function}
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

parse_parameters(Body) ->
    case
        re:run(
            Body,
            "<parameter=([^>]*)>(.*?)</parameter>",
            [dotall, global, {capture, [1, 2], binary}]
        )
    of
        {match, Matches} ->
            maps:from_list([{string:trim(K), coerce(string:trim(V))} || [K, V] <- Matches]);
        nomatch ->
            #{}
    end.

%% Recover a typed value from the stringly-typed parameter body: decode as
%% JSON when it parses (int / bool / object / array / quoted string), keep
%% the raw binary otherwise (bare unquoted strings are not valid JSON).
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
    Params = [
        [<<"<parameter=">>, K, <<">\n">>, render_value(V), <<"\n</parameter>\n">>]
     || {K, V} <- maps:to_list(Args)
    ],
    iolist_to_binary([
        ?START,
        <<"\n<function=">>,
        Name,
        <<">\n">>,
        Params,
        <<"</function>\n">>,
        ?END
    ]).

render_value(V) when is_binary(V) -> V;
render_value(V) -> json:encode(V).

%% =============================================================================
%% render_prompt (native tool system block, Qwen3-Coder shape)
%% =============================================================================

-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    Block = [
        <<"You have access to the following functions:\n\n">>,
        <<"<tools>">>,
        [render_function(T) || T <- Tools],
        <<"\n</tools>\n\n">>,
        call_format_instructions()
    ],
    barrel_inference_server_tool_format:append_system(System, iolist_to_binary(Block)).

render_function(#{name := Name, description := Desc, schema := Schema}) ->
    [
        <<"\n<function>\n<name>">>,
        Name,
        <<"</name>\n<description>">>,
        string:trim(to_bin(Desc)),
        <<"</description>\n<parameters>">>,
        render_parameters(Schema),
        <<"\n</parameters>\n</function>">>
    ].

render_parameters(Schema) when is_map(Schema) ->
    Props = maps:get(<<"properties">>, Schema, #{}),
    Required = maps:get(<<"required">>, Schema, []),
    [
        [render_parameter(Name, Fields) || {Name, Fields} <- maps:to_list(Props)],
        item_list(Required, <<"required">>)
    ];
render_parameters(_) ->
    [].

render_parameter(Name, Fields) when is_map(Fields) ->
    Handled = [<<"type">>, <<"description">>, <<"enum">>, <<"required">>],
    [
        <<"\n<parameter>\n<name>">>,
        Name,
        <<"</name>">>,
        opt_tag(<<"type">>, maps:get(<<"type">>, Fields, undefined)),
        opt_tag(<<"description">>, maps:get(<<"description">>, Fields, undefined)),
        item_list(maps:get(<<"enum">>, Fields, []), <<"enum">>),
        [extra_tag(K, V) || {K, V} <- maps:to_list(Fields), not lists:member(K, Handled)],
        <<"\n</parameter>">>
    ];
render_parameter(Name, _) ->
    [<<"\n<parameter>\n<name>">>, Name, <<"</name>\n</parameter>">>].

%% `\n<name>inner</name>'.
tag(Name, Inner) ->
    [<<"\n<">>, Name, <<">">>, Inner, <<"</">>, Name, <<">">>].

%% A scalar tag, omitted when the field is absent.
opt_tag(_Tag, undefined) -> [];
opt_tag(Tag, Value) -> tag(Tag, scalar(Value)).

%% A non-handled JSON-schema key, rendered as <key>json</key> (mirrors the
%% Qwen3-Coder template's pass-through of extra parameter fields).
extra_tag(Key, Value) when is_map(Value); is_list(Value) -> tag(Key, json:encode(Value));
extra_tag(Key, Value) -> tag(Key, scalar(Value)).

%% A `<tag>[`a`, `b`]</tag>' list (backtick-quoted), omitted when empty.
item_list([], _Tag) ->
    [];
item_list(Items, Tag) when is_list(Items) ->
    Inner = lists:join(<<", ">>, [[<<"`">>, scalar(I), <<"`">>] || I <- Items]),
    [<<"\n<">>, Tag, <<">[">>, Inner, <<"]</">>, Tag, <<">">>];
item_list(_, _) ->
    [].

call_format_instructions() ->
    [
        <<"If you choose to call a function ONLY reply in the following format with ">>,
        <<"NO suffix:\n\n">>,
        ?START,
        <<"\n<function=example_function_name>\n">>,
        <<"<parameter=example_parameter_1>\nvalue_1\n</parameter>\n">>,
        <<"<parameter=example_parameter_2>\nvalue_2\n</parameter>\n">>,
        <<"</function>\n">>,
        ?END,
        <<"\n\n<IMPORTANT>\nReminder:\n">>,
        <<"- Function calls MUST follow the specified format: an inner ">>,
        <<"<function=...></function> block must be nested within ">>,
        <<"<tool_call></tool_call> XML tags\n">>,
        <<"- Required parameters MUST be specified\n">>,
        <<"- Put the entire function call reply on one line\n">>,
        <<"</IMPORTANT>">>
    ].

scalar(V) when is_binary(V) -> V;
scalar(V) when is_atom(V) -> atom_to_binary(V, utf8);
scalar(V) when is_integer(V) -> integer_to_binary(V);
scalar(V) when is_float(V) -> float_to_binary(V, [short]);
scalar(V) -> json:encode(V).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(_) -> <<>>.
