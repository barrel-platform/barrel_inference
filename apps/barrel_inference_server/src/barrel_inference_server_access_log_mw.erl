%%% livery middleware: access log emitting one `logger:notice/2' line
%%% per request in the same format as the legacy cowboy_stream-based
%%% `barrel_inference_server_access_log'. Operators parse the line
%%% directly; keeping the format stable means existing log pipelines
%%% need no change at migration time.
%%%
%%% Disabled when `application:get_env(barrel_inference_server,
%%% access_log, true)' is `false'.

-module(barrel_inference_server_access_log_mw).
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(), term()) ->
    livery_resp:resp().
call(Req, Next, _State) ->
    Started = erlang:monotonic_time(microsecond),
    Resp = Next(Req),
    case is_enabled() of
        true ->
            DurationUs = erlang:monotonic_time(microsecond) - Started,
            logger:notice(
                "~s ~s ~p (~.2fms) ~s ~s",
                [
                    or_dash(livery_req:method(Req)),
                    or_dash(livery_req:path(Req)),
                    livery_resp:status(Resp),
                    DurationUs / 1000.0,
                    or_dash(livery_req:req_id(Req)),
                    fmt_peer(livery_req:peer(Req))
                ]
            );
        false ->
            ok
    end,
    Resp.

is_enabled() ->
    application:get_env(barrel_inference_server, access_log, true).

fmt_peer({Ip, Port}) ->
    iolist_to_binary(io_lib:format("~s:~p", [inet:ntoa(Ip), Port]));
fmt_peer(_) ->
    <<"-">>.

or_dash(undefined) -> <<"-">>;
or_dash(B) when is_binary(B) -> B;
or_dash(L) when is_list(L) -> L.
