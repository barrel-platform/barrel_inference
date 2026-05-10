%%% /metrics scrape endpoint. Refreshes erllama cache gauges from the
%%% live counters, then returns instrument's Prometheus text format.

-module(erllama_server_h_metrics).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, Opts) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            erllama_server_metrics:update_cache_gauges(),
            Body = instrument_prometheus:format(),
            Req1 = cowboy_req:reply(
                200,
                #{<<"content-type">> => instrument_prometheus:content_type()},
                Body,
                Req0
            ),
            {ok, Req1, Opts};
        _ ->
            Req1 = cowboy_req:reply(405, #{}, <<>>, Req0),
            {ok, Req1, Opts}
    end.
