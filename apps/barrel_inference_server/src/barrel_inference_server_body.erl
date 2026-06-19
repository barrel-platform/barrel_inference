%%%-------------------------------------------------------------------
%%% @doc HTTP request body reader.
%%%
%%% Livery delivers the body as `{stream, Reader}` on the request
%%% value; `livery_body:read_all/2` streams it with a `max` bound.
%%% Callers get `{ok, Body, Req}` on success or `{too_large, Req}`
%%% once the next chunk would push past the cap; the latter maps to
%%% 413 / `request_too_large` at the handler.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_inference_server_body).

-export([read/1, read/2]).

read(Req) ->
    read(Req, barrel_inference_server_config:max_request_body_bytes()).

dbg_body(Max, {ok, B, _}) ->
    io:format(user, "[DEBUG body] Max=~p ok bytes=~p~n", [Max, byte_size(B)]);
dbg_body(Max, {error, E, _}) ->
    io:format(user, "[DEBUG body] Max=~p err=~p~n", [Max, E]).

read(Req, Max) ->
    case livery_req:body(Req) of
        {stream, Reader} ->
            R = livery_body:read_all(Reader, 30000, Max + 1),
            dbg_body(Max, R),
            case R of
                {ok, Body, _R1} when byte_size(Body) > Max -> {too_large, Req};
                {ok, Body, _R1} -> {ok, Body, Req};
                {error, _R, _R1} -> {too_large, Req}
            end;
        {buffered, Body} when is_binary(Body), byte_size(Body) > Max ->
            {too_large, Req};
        {buffered, Body} when is_binary(Body) ->
            {ok, Body, Req};
        {buffered, Body} ->
            Bin = iolist_to_binary(Body),
            case byte_size(Bin) > Max of
                true -> {too_large, Req};
                false -> {ok, Bin, Req}
            end;
        empty ->
            {ok, <<>>, Req}
    end.
