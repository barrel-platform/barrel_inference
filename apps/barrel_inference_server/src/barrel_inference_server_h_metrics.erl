%%% /metrics scrape endpoint. Refreshes barrel_inference cache gauges from the
%%% live counters, then returns instrument's Prometheus text format.

-module(barrel_inference_server_h_metrics).

-export([handle/1]).

handle(_Req) ->
    barrel_inference_server_metrics:update_cache_gauges(),
    Body = iolist_to_binary(instrument_prometheus:format()),
    livery_resp:text(
        200,
        [{<<"content-type">>, instrument_prometheus:content_type()}],
        Body
    ).
