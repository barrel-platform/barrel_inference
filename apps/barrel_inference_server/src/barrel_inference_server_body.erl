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

read(Req, Max) ->
    case livery_req:body(Req) of
        {stream, Reader} ->
            %% Pass our cap as `Max' so livery's default 16 MiB ceiling
            %% does not pre-empt the configured `max_request_body_bytes'
            %% (defaults to 256 MiB). Beyond `Max' livery returns
            %% `{error, {limit, max_size}, _}' which maps to 413 the same
            %% way our post-read cap did.
            case livery_body:read_all(Reader, 30000, Max + 1) of
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
