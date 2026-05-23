%%%-------------------------------------------------------------------
%%% @doc HTTP request body reader.
%%%
%%% Cowboy's `read_body/1,2' returns `{more, _, _}' on any non-final
%%% chunk (HTTP `nofin' frame, the per-call `length' buffer filling,
%%% or the per-call `period' elapsing) - not only on size overflow.
%%% A handler that maps `{more, _, _}' directly to 413 rejects every
%%% body cowboy happens to deliver in more than one chunk, including
%%% small bodies on slow sockets or chunked uploads.
%%%
%%% This module loops `read_body/1' until cowboy reports `{ok, _, _}'
%%% (the final chunk), enforcing a hard upper bound on the running
%%% total. Callers get `{ok, Body, Req}' on success or
%%% `{too_large, Req}' once the next chunk would push past the cap;
%%% the latter maps to 413 / `request_too_large' at the handler.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_inference_server_body).

-export([read/1, read/2]).

-spec read(cowboy_req:req()) ->
    {ok, binary(), cowboy_req:req()} | {too_large, cowboy_req:req()}.
read(Req) ->
    read(Req, barrel_inference_server_config:max_request_body_bytes()).

-spec read(cowboy_req:req(), pos_integer()) ->
    {ok, binary(), cowboy_req:req()} | {too_large, cowboy_req:req()}.
read(Req, Max) ->
    read_loop(Req, Max, [], 0).

read_loop(Req0, Max, Acc, Size) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req1} ->
            Total = Size + byte_size(Data),
            case Total > Max of
                true -> {too_large, Req1};
                false -> {ok, iolist_to_binary([Acc, Data]), Req1}
            end;
        {more, Data, Req1} ->
            Total = Size + byte_size(Data),
            case Total > Max of
                true -> {too_large, Req1};
                false -> read_loop(Req1, Max, [Acc, Data], Total)
            end
    end.
