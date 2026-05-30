%%% llama-pythonic tool-call format. Used by Llama 3.2 Instruct (1B, 3B)
%%% and Llama 3.3 70B Instruct for zero-shot tool calls. The wire shape:
%%%
%%%   [get_weather(city='Paris', metric='celsius'), get_time(tz='UTC')]<|eot_id|>
%%%
%%% (Built-in tools in 3.3 still use the Llama 3.1 `<|python_tag|>JSON<|eom_id|>'
%%% envelope, which is covered by `llama-python-tag'; this family is for the
%%% zero-shot pythonic shape that became the default in 3.2.)
%%%
%%% The model emits the full bracket-list at the END of its turn (no
%%% partial-call streaming is meaningful), so this family opts into the
%%% handlers' post-parse path via `post_parse_mode() -> pythonic'. The
%%% handler runs `parse_all/1' on the accumulated response buffer at
%%% `barrel_inference_done' and injects the calls as if they had been
%%% captured by the native marker path.
%%%
%%% The parser is tolerant of:
%%% - single OR double quoted strings (`'foo'' and `"foo"');
%%% - Python literals (`True', `False', `None') AND JSON equivalents
%%%   (`true', `false', `null');
%%% - integers and floats (including negative + scientific notation);
%%% - nested lists `[v, ...]' and dicts `{k: v, ...}' (with string or
%%%   identifier keys);
%%% - whitespace anywhere between tokens;
%%% - a trailing `<|eot_id|>' literal (if it ever survives detok as
%%%   plain text rather than as a dropped control token).
%%%
%%% `canonicalise/1' renders the Python-literal shape (single-quoted
%%% strings, `True'/`False'/`None') so a round-trip is byte-stable.

-module(barrel_inference_server_tool_format_llama_pythonic).
-behaviour(barrel_inference_server_tool_format).

-export([parse/1, canonicalise/1, render_prompt/2]).
-export([parse_all/1, post_parse_mode/0]).
-export([family_name/0, detect/1]).

-define(EOT, <<"<|eot_id|>">>).

family_name() -> <<"llama-pythonic">>.

%% Llama 3.2 / 3.3 zero-shot pythonic. Llama templates that have
%% `<|python_tag|>' continue to detect as `llama-python-tag'; this
%% family requires `<|eot_id|>' (every Llama 3.x template has it)
%% AND the absence of `<|python_tag|>' AND a pythonic / python-list
%% mention in the tool instructions.
-spec detect(binary()) -> {detected, undefined} | not_detected.
detect(T) when is_binary(T) ->
    Has = fun(M) -> binary:match(T, M) =/= nomatch end,
    HasEot = Has(?EOT),
    HasPyTag = Has(<<"<|python_tag|>">>),
    HasPythonic = Has(<<"pythonic">>) orelse Has(<<"python list">>),
    case HasEot andalso not HasPyTag andalso HasPythonic of
        true -> {detected, undefined};
        false -> not_detected
    end.

%% =============================================================================
%% Behaviour callbacks
%% =============================================================================

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    %% Single-call entry point (registry dispatch). For multi-call
    %% lists, returns the FIRST call to match the existing
    %% single-map contract; `parse_all/1' surfaces them all and is
    %% the entry the handler post-parse uses.
    Body = strip_list_wrapper(strip_eot(string:trim(Bin))),
    try
        case parse_call(skip_ws(Body)) of
            {ok, Call, _Rest} -> {ok, Call};
            Err -> Err
        end
    catch
        throw:{parse_error, Reason} -> {error, Reason}
    end.

-spec parse_all(binary()) -> {ok, [map()]} | {error, term()}.
parse_all(Bin) when is_binary(Bin) ->
    Body = strip_list_wrapper(strip_eot(string:trim(Bin))),
    try parse_calls(skip_ws(Body), []) of
        {ok, []} -> {error, no_calls};
        Other -> Other
    catch
        throw:{parse_error, Reason} -> {error, Reason}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary([<<"[">>, render_call(Name, Args), <<"]">>]).

-spec render_prompt([map()], binary() | undefined) -> binary().
render_prompt(Tools, System) ->
    %% Llama 3.2 / 3.3's tool DECLARATION block is still JSON-Schema per
    %% Meta's official docs; only the model OUTPUT moved to pythonic.
    %% Pin the output shape with a short instruction line so the model
    %% emits the exact wire form `parse_all/1' expects.
    Sigs = barrel_inference_server_tool_format:tool_signatures(Tools),
    Block = iolist_to_binary([
        <<"You have the following tools available. To call any of them, ">>,
        <<"respond with a Python-style list of one or more calls, each ">>,
        <<"`function_name(param1=value1, param2=value2)`. Use Python ">>,
        <<"literals (`True`/`False`/`None`) or JSON literals ">>,
        <<"(`true`/`false`/`null`) for argument values. Example:\n">>,
        <<"[get_weather(city='Paris', metric='celsius')]\n\n">>,
        <<"Available tools:\n">>,
        json:encode(Sigs)
    ]),
    barrel_inference_server_tool_format:append_system(System, Block).

%% Family-declared post-parse mode. The handlers' `barrel_inference_done'
%% branch dispatches on this and runs `parse_all/1' on the response
%% buffer for marker-less families.
-spec post_parse_mode() -> pythonic.
post_parse_mode() -> pythonic.

%% =============================================================================
%% Strippers
%% =============================================================================

%% Strip a literal trailing `<|eot_id|>' if it survives detok as plain
%% text. The token IS a control token (drops under `special=false') so
%% in the canonical path the body never carries it; this is defensive
%% for raw / scanner-fallback paths.
strip_eot(Bin) ->
    barrel_inference_server_tool_format:strip_suffix(Bin, ?EOT).

%% Strip the outer `[' / `]' wrapper of a call list. Internal nested
%% lists / dicts (inside argument values) are handled by `parse_value/1',
%% so we just check the outer bracket pair here.
strip_list_wrapper(Bin) ->
    Trimmed = string:trim(Bin),
    Sz = byte_size(Trimmed),
    case Sz >= 2 of
        false ->
            Trimmed;
        true ->
            case {binary:part(Trimmed, 0, 1), binary:part(Trimmed, Sz - 1, 1)} of
                {<<"[">>, <<"]">>} ->
                    string:trim(binary:part(Trimmed, 1, Sz - 2));
                _ ->
                    Trimmed
            end
    end.

%% =============================================================================
%% Call list parsing
%% =============================================================================

parse_calls(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
parse_calls(Bin, Acc) ->
    case parse_call(Bin) of
        {ok, Call, Rest} ->
            case skip_ws(Rest) of
                <<",", Rest2/binary>> ->
                    parse_calls(skip_ws(Rest2), [Call | Acc]);
                <<>> ->
                    {ok, lists:reverse([Call | Acc])};
                _ ->
                    throw({parse_error, expected_comma_or_end_of_list})
            end;
        Err ->
            Err
    end.

parse_call(Bin) ->
    {Name, Rest1} = parse_identifier(skip_ws(Bin)),
    case Name of
        <<>> ->
            {error, expected_call_name};
        _ ->
            case skip_ws(Rest1) of
                <<"(", Rest2/binary>> ->
                    {Args, Rest3} = parse_kwargs(skip_ws(Rest2), #{}),
                    {ok, #{name => Name, arguments => Args}, Rest3};
                _ ->
                    {error, expected_open_paren}
            end
    end.

parse_kwargs(<<")", Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_kwargs(Bin, Acc) ->
    {Key, Rest1} = parse_identifier(skip_ws(Bin)),
    case Key of
        <<>> -> throw({parse_error, expected_kwarg_name});
        _ -> ok
    end,
    case skip_ws(Rest1) of
        <<"=", Rest2/binary>> ->
            {Value, Rest3} = parse_value(skip_ws(Rest2)),
            Acc1 = Acc#{Key => Value},
            case skip_ws(Rest3) of
                <<",", Rest4/binary>> ->
                    parse_kwargs(skip_ws(Rest4), Acc1);
                <<")", Rest4/binary>> ->
                    {Acc1, Rest4};
                _ ->
                    throw({parse_error, expected_comma_or_close_paren})
            end;
        _ ->
            throw({parse_error, expected_equals})
    end.

%% =============================================================================
%% Value parsing
%% =============================================================================

parse_value(<<"'", Rest/binary>>) -> parse_string($', Rest, <<>>);
parse_value(<<"\"", Rest/binary>>) -> parse_string($", Rest, <<>>);
parse_value(<<"True", Rest/binary>>) -> {true, Rest};
parse_value(<<"true", Rest/binary>>) -> {true, Rest};
parse_value(<<"False", Rest/binary>>) -> {false, Rest};
parse_value(<<"false", Rest/binary>>) -> {false, Rest};
parse_value(<<"None", Rest/binary>>) -> {null, Rest};
parse_value(<<"null", Rest/binary>>) -> {null, Rest};
parse_value(<<"[", Rest/binary>>) -> parse_list(skip_ws(Rest), []);
parse_value(<<"{", Rest/binary>>) -> parse_dict(skip_ws(Rest), #{});
parse_value(Bin) -> parse_number(Bin).

%% Strings: backslash escapes the next character verbatim (Python
%% convention). We do NOT try to interpret `\\n', `\\t', etc. - the
%% model rarely emits them in tool args and naive interpretation would
%% lose round-trip stability.
parse_string(_Quote, <<>>, _Acc) ->
    throw({parse_error, unterminated_string});
parse_string(Quote, <<"\\", C, Rest/binary>>, Acc) ->
    parse_string(Quote, Rest, <<Acc/binary, C>>);
parse_string(Quote, <<Quote, Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_string(Quote, <<C, Rest/binary>>, Acc) ->
    parse_string(Quote, Rest, <<Acc/binary, C>>).

parse_number(Bin) ->
    {NumStr, Rest} = read_number_chars(Bin, <<>>),
    case NumStr of
        <<>> ->
            throw({parse_error, expected_value});
        _ ->
            try
                case binary:match(NumStr, [<<".">>, <<"e">>, <<"E">>]) of
                    nomatch -> {binary_to_integer(NumStr), Rest};
                    _ -> {binary_to_float(NumStr), Rest}
                end
            catch
                _:_ -> throw({parse_error, malformed_number})
            end
    end.

read_number_chars(<<C, Rest/binary>>, Acc) when
    C =:= $-;
    C =:= $+;
    C >= $0, C =< $9;
    C =:= $.;
    C =:= $e;
    C =:= $E
->
    read_number_chars(Rest, <<Acc/binary, C>>);
read_number_chars(Bin, Acc) ->
    {Acc, Bin}.

parse_list(<<"]", Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
parse_list(Bin, Acc) ->
    {V, Rest1} = parse_value(skip_ws(Bin)),
    case skip_ws(Rest1) of
        <<",", Rest2/binary>> ->
            parse_list(skip_ws(Rest2), [V | Acc]);
        <<"]", Rest2/binary>> ->
            {lists:reverse([V | Acc]), Rest2};
        _ ->
            throw({parse_error, expected_comma_or_close_bracket})
    end.

parse_dict(<<"}", Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_dict(Bin, Acc) ->
    {K, Rest1} = parse_dict_key(skip_ws(Bin)),
    case skip_ws(Rest1) of
        <<":", Rest2/binary>> ->
            {V, Rest3} = parse_value(skip_ws(Rest2)),
            Acc1 = Acc#{K => V},
            case skip_ws(Rest3) of
                <<",", Rest4/binary>> ->
                    parse_dict(skip_ws(Rest4), Acc1);
                <<"}", Rest4/binary>> ->
                    {Acc1, Rest4};
                _ ->
                    throw({parse_error, expected_comma_or_close_dict})
            end;
        _ ->
            throw({parse_error, expected_colon})
    end.

parse_dict_key(<<"'", Rest/binary>>) ->
    parse_string($', Rest, <<>>);
parse_dict_key(<<"\"", Rest/binary>>) ->
    parse_string($", Rest, <<>>);
parse_dict_key(Bin) ->
    case parse_identifier(Bin) of
        {<<>>, _} -> throw({parse_error, expected_dict_key});
        Pair -> Pair
    end.

%% =============================================================================
%% Lexer primitives
%% =============================================================================

parse_identifier(Bin) ->
    parse_identifier(Bin, <<>>).

parse_identifier(<<C, Rest/binary>>, Acc) when
    C >= $a, C =< $z;
    C >= $A, C =< $Z;
    C >= $0, C =< $9;
    C =:= $_
->
    parse_identifier(Rest, <<Acc/binary, C>>);
parse_identifier(Bin, Acc) ->
    {Acc, Bin}.

skip_ws(<<C, Rest/binary>>) when
    C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r
->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.

%% =============================================================================
%% Canonicalise (Python-literal output)
%% =============================================================================

render_call(Name, Args) ->
    [Name, <<"(">>, render_kwargs(maps:to_list(Args)), <<")">>].

render_kwargs([]) ->
    [];
render_kwargs([{K, V}]) ->
    [K, <<"=">>, render_value(V)];
render_kwargs([{K, V} | Rest]) ->
    [K, <<"=">>, render_value(V), <<", ">> | render_kwargs(Rest)].

render_value(true) ->
    <<"True">>;
render_value(false) ->
    <<"False">>;
render_value(null) ->
    <<"None">>;
render_value(N) when is_integer(N) ->
    integer_to_binary(N);
render_value(N) when is_float(N) ->
    float_to_binary(N, [{decimals, 6}, compact]);
render_value(S) when is_binary(S) ->
    %% Single-quoted Python string. Escape backslashes and single quotes.
    E1 = binary:replace(S, <<"\\">>, <<"\\\\">>, [global]),
    E2 = binary:replace(E1, <<"'">>, <<"\\'">>, [global]),
    <<$', E2/binary, $'>>;
render_value(L) when is_list(L) ->
    [<<"[">>, lists:join(<<", ">>, [render_value(V) || V <- L]), <<"]">>];
render_value(M) when is_map(M) ->
    [
        <<"{">>,
        lists:join(<<", ">>, [
            [render_value(K), <<": ">>, render_value(V)]
         || {K, V} <- maps:to_list(M)
        ]),
        <<"}">>
    ].
