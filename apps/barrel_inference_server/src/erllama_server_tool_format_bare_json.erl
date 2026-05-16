%%% bare_json tool-call format. The trivial format: a single JSON
%%% object with `name' and `arguments' (or `parameters') keys, no
%%% surrounding delimiters:
%%%
%%%   {"name":"get_weather","arguments":{"city":"Paris"}}
%%%
%%% Primary use is the canonicaliser side: when a history `tool_use'
%%% block from a model whose backend has no `tool_call_markers'
%%% configured needs to be replayed, the canonicaliser produces the
%%% bare-JSON form that the model's prompt template expects. The
%%% parser is included for round-trip symmetry and for the rare
%%% edge case where an operator wires markers around a model that
%%% truly does emit bare JSON.
%%%
%%% Models without `tool_call_markers' set on `load_model/2' do NOT
%%% emit the `erllama_tool_call_end' wire event - the legacy
%%% `mode = tool_buffer' accumulator in the handlers still services
%%% them. This module is the canonicaliser fallback for that path
%%% on the render side, not a parser for new capture-path traffic.

-module(erllama_server_tool_format_bare_json).
-behaviour(erllama_server_tool_format).

-export([parse/1, canonicalise/1]).

-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Trimmed = string:trim(Bin),
    case Trimmed of
        <<>> -> {error, empty};
        _ -> decode_payload(Trimmed)
    end.

decode_payload(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} when
            is_binary(Name), is_map(Args)
        ->
            {ok, #{name => Name, arguments => Args}};
        #{<<"name">> := Name, <<"parameters">> := Args} when
            is_binary(Name), is_map(Args)
        ->
            {ok, #{name => Name, arguments => Args}};
        #{<<"name">> := Name} when is_binary(Name) ->
            {ok, #{name => Name, arguments => #{}}};
        _ ->
            {error, malformed_payload}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec canonicalise(map()) -> binary().
canonicalise(#{name := Name, arguments := Args}) when
    is_binary(Name), is_map(Args)
->
    iolist_to_binary(json:encode(#{<<"name">> => Name, <<"arguments">> => Args})).
