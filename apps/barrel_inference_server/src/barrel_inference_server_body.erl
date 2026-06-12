%%%-------------------------------------------------------------------
%%% @doc HTTP request body reader.
%%%
%%% Two wire surfaces during the cowboy → livery migration:
%%%
%%%  - Cowboy's `read_body/1,2' returns `{more, _, _}' on any non-final
%%%    chunk (HTTP `nofin' frame, the per-call `length' buffer filling,
%%%    or the per-call `period' elapsing) - not only on size overflow.
%%%    A handler that maps `{more, _, _}' directly to 413 rejects every
%%%    body cowboy happens to deliver in more than one chunk, including
%%%    small bodies on slow sockets or chunked uploads. This module
%%%    loops `read_body/1' until cowboy reports `{ok, _, _}' (the final
%%%    chunk), enforcing the hard cap on the running total.
%%%
%%%  - Livery delivers the body as `{stream, Reader}' on the request
%%%    value; `livery_body:read_all/2' streams it with a `max' bound.
%%%
%%% Callers get `{ok, Body, Req}' on success or `{too_large, Req}' once
%%% the next chunk would push past the cap; the latter maps to
%%% 413 / `request_too_large' at the handler. The `Req' is the same
%%% record shape the caller passed in.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_inference_server_body).

-export([read/1, read/2]).

read(Req) ->
    read(Req, barrel_inference_server_config:max_request_body_bytes()).

read(Req, Max) ->
    case is_livery_req(Req) of
        true -> read_livery(Req, Max);
        false -> read_cowboy(Req, Max)
    end.

%%====================================================================
%% Cowboy
%%====================================================================

read_cowboy(Req, Max) ->
    read_cowboy_loop(Req, Max, [], 0).

read_cowboy_loop(Req0, Max, Acc, Size) ->
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
                false -> read_cowboy_loop(Req1, Max, [Acc, Data], Total)
            end
    end.

%%====================================================================
%% Livery
%%====================================================================

%% livery delivers the body as `{stream, Reader}' on the request value.
%% `livery_body:read_all/2' takes that reader and a timeout, drains the
%% body, and returns the bytes. The body cap is enforced after the read
%% rather than as a `max' option (livery_body doesn't expose a per-call
%% cap; we accept the body and reject above the cap so the public
%% `{too_large, Req}' shape is preserved).
read_livery(Req, Max) ->
    case livery_req:body(Req) of
        {stream, Reader} ->
            case livery_body:read_all(Reader, 30000) of
                {ok, Body, _Reader1} when byte_size(Body) > Max ->
                    {too_large, Req};
                {ok, Body, _Reader1} ->
                    {ok, Body, Req};
                {error, _Reason, _Reader1} ->
                    {too_large, Req}
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

%%====================================================================
%% Dispatch
%%====================================================================

%% Livery requests are records (`#livery_req{}'); cowboy requests are
%% maps. Distinguish on shape so the public API takes either.
is_livery_req(Req) when is_tuple(Req), tuple_size(Req) > 0 ->
    element(1, Req) =:= livery_req;
is_livery_req(_) ->
    false.
