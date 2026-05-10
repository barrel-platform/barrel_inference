%%% Cowboy stream handler that emits one access-log line per request
%%% via `logger:info/2`. Enabled by setting the `access_log` app env
%%% to `true` (default).
%%%
%%% Log format (logger structured metadata; the default formatter
%%% renders it as a single line):
%%%
%%%   level => info
%%%   msg   => "GET /v1/models 200 (3.2ms) req_42 ::1"
%%%   meta  => #{
%%%     method => binary(),
%%%     path   => binary(),
%%%     status => non_neg_integer(),
%%%     duration_us => non_neg_integer(),
%%%     request_id  => binary() | undefined,
%%%     remote => string()
%%%   }
%%%
%%% Operators that ship logs as JSON can pair this with a
%%% logger_formatter that emits all the meta fields.

-module(erllama_server_access_log).
-behaviour(cowboy_stream).

-export([init/3, data/4, info/3, terminate/3, early_error/5]).

-record(state, {
    next :: term(),
    method :: binary() | undefined,
    path :: binary() | undefined,
    request_id :: binary() | undefined,
    remote :: string() | undefined,
    started_us :: integer(),
    status :: non_neg_integer() | undefined
}).

init(StreamID, Req, Opts) ->
    {Commands, Next} = cowboy_stream:init(StreamID, Req, Opts),
    Method = maps:get(method, Req, undefined),
    Path = maps:get(path, Req, undefined),
    Headers = maps:get(headers, Req, #{}),
    HeaderName = erllama_server_config:request_id_header(),
    RequestId = maps:get(HeaderName, Headers, undefined),
    Remote = fmt_peer(maps:get(peer, Req, undefined)),
    {Commands, #state{
        next = Next,
        method = Method,
        path = Path,
        request_id = RequestId,
        remote = Remote,
        started_us = erlang:monotonic_time(microsecond)
    }}.

data(StreamID, IsFin, Data, S = #state{next = N}) ->
    {Commands, N1} = cowboy_stream:data(StreamID, IsFin, Data, N),
    {Commands, S#state{next = N1}}.

%% Capture the response status from the first `response` or
%% `headers` command before delegating to the next handler.
info(StreamID, Info, S = #state{next = N}) ->
    S1 = capture_status(Info, S),
    {Commands, N1} = cowboy_stream:info(StreamID, Info, N),
    {Commands, S1#state{next = N1}}.

terminate(StreamID, Reason, S = #state{next = N}) ->
    emit(S, Reason),
    cowboy_stream:terminate(StreamID, Reason, N).

early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    %% Cowboy invokes this before init/3 when the request line is
    %% malformed. Log a minimal line; no per-stream state yet.
    HeaderName =
        try
            erllama_server_config:request_id_header()
        catch
            _:_ -> <<"x-request-id">>
        end,
    Headers = maps:get(headers, PartialReq, #{}),
    case is_enabled() of
        true ->
            logger:notice(
                "~s ~s ~p (~p) ~s ~s",
                [
                    maps:get(method, PartialReq, <<"-">>),
                    maps:get(path, PartialReq, <<"-">>),
                    http_status(Resp),
                    Reason,
                    maps:get(HeaderName, Headers, <<"-">>),
                    fmt_peer(maps:get(peer, PartialReq, undefined))
                ]
            );
        false ->
            ok
    end,
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).

%%====================================================================
%% Internal
%%====================================================================

capture_status({response, Status, _Headers, _Body}, S) ->
    S#state{status = http_status(Status)};
capture_status({headers, Status, _Headers}, S) ->
    S#state{status = http_status(Status)};
capture_status(_, S) ->
    S.

emit(S, _Reason) ->
    case is_enabled() of
        true ->
            DurationUs = erlang:monotonic_time(microsecond) - S#state.started_us,
            Status =
                case S#state.status of
                    undefined -> 0;
                    X -> X
                end,
            logger:notice(
                "~s ~s ~p (~.2fms) ~s ~s",
                [
                    or_dash(S#state.method),
                    or_dash(S#state.path),
                    Status,
                    DurationUs / 1000.0,
                    or_dash(S#state.request_id),
                    or_dash(S#state.remote)
                ]
            );
        false ->
            ok
    end.

is_enabled() ->
    application:get_env(erllama_server, access_log, true).

http_status(I) when is_integer(I) -> I;
http_status({status, I, _}) when is_integer(I) -> I;
http_status(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<" ">>) of
        [N | _] -> binary_to_integer(N);
        _ -> 0
    end;
http_status(_) ->
    0.

fmt_peer({Ip, Port}) ->
    lists:flatten(io_lib:format("~s:~p", [inet:ntoa(Ip), Port]));
fmt_peer(_) ->
    "-".

or_dash(undefined) -> <<"-">>;
or_dash(B) when is_binary(B) -> B;
or_dash(L) when is_list(L) -> L.
