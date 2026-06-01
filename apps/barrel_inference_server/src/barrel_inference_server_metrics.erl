%%% Thin facade over `instrument` for metrics emitted by the server.
%%%
%%% Instruments are created once at app start and stashed in
%%% `persistent_term`, so the hot path is one persistent_term:get/1
%%% plus one NIF call per increment. No ETS.
%%%
%%% `/metrics` calls instrument_prometheus:format/0 directly; this
%%% module only has to keep the instruments alive and expose typed
%%% helpers the rest of the code calls.

-module(barrel_inference_server_metrics).

-export([
    init/0,
    record_request/4,
    observe_request_duration/3,
    observe_prefill/2,
    observe_engine_admit/3,
    observe_generation_tps/2,
    inc_completion_tokens/2,
    inc_prompt_tokens/2,
    inc_cache_hit/2,
    inc_pool_exhausted/1,
    inc_queue_dropped/2,
    set_queue_depth/2,
    inc_active_streams/1,
    dec_active_streams/1,
    set_models_loaded/1,
    update_cache_gauges/0
]).

-define(METER_NAME, <<"barrel_inference_server">>).
-define(LATENCY_BUCKETS, [
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.5,
    1,
    2.5,
    5,
    10,
    30,
    60,
    300
]).
-define(PREFILL_BUCKETS, [
    0.01,
    0.05,
    0.1,
    0.25,
    0.5,
    1,
    2.5,
    5,
    10,
    30,
    60,
    300
]).
-define(TPS_BUCKETS, [1, 5, 10, 25, 50, 100, 250, 500]).

%%====================================================================
%% Lifecycle
%%====================================================================

-spec init() -> ok.
init() ->
    M = instrument_meter:get_meter(?METER_NAME),
    put_inst(
        requests_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_requests_total">>,
            #{description => <<"Total HTTP requests">>}
        )
    ),
    put_inst(
        request_duration,
        instrument_meter:create_histogram(
            M,
            <<"barrel_inference_request_duration_seconds">>,
            #{
                description => <<"HTTP request duration">>,
                unit => <<"s">>,
                boundaries => ?LATENCY_BUCKETS
            }
        )
    ),
    put_inst(
        prefill_duration,
        instrument_meter:create_histogram(
            M,
            <<"barrel_inference_prefill_duration_seconds">>,
            #{
                description => <<"Prefill latency from admit to first token">>,
                unit => <<"s">>,
                boundaries => ?PREFILL_BUCKETS
            }
        )
    ),
    put_inst(
        engine_admit_duration,
        instrument_meter:create_histogram(
            M,
            <<"barrel_inference_engine_admit_duration_seconds">>,
            #{
                description =>
                    <<"Engine admission latency (grammar compile + prefill) per infer op">>,
                unit => <<"s">>,
                boundaries => ?PREFILL_BUCKETS
            }
        )
    ),
    put_inst(
        gen_tps,
        instrument_meter:create_histogram(
            M,
            <<"barrel_inference_generation_tokens_per_second">>,
            #{
                description => <<"Generation throughput">>,
                unit => <<"tok/s">>,
                boundaries => ?TPS_BUCKETS
            }
        )
    ),
    put_inst(
        completion_tokens_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_completion_tokens_total">>,
            #{description => <<"Tokens generated">>}
        )
    ),
    put_inst(
        prompt_tokens_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_prompt_tokens_total">>,
            #{description => <<"Tokens consumed from prompt">>}
        )
    ),
    put_inst(
        cache_hits_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_cache_hits_total">>,
            #{description => <<"barrel_inference cache hits by kind">>}
        )
    ),
    put_inst(
        pool_exhausted_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_pool_exhausted_total">>,
            #{description => <<"Requests rejected with pool_exhausted">>}
        )
    ),
    put_inst(
        queue_dropped_total,
        instrument_meter:create_counter(
            M,
            <<"barrel_inference_queue_dropped_total">>,
            #{description => <<"Queued requests dropped">>}
        )
    ),
    put_inst(
        queue_depth,
        instrument_meter:create_gauge(
            M,
            <<"barrel_inference_queue_depth">>,
            #{description => <<"Queued requests right now">>}
        )
    ),
    put_inst(
        active_streams,
        instrument_meter:create_gauge(
            M,
            <<"barrel_inference_active_streams">>,
            #{description => <<"Streams currently delivering tokens">>}
        )
    ),
    put_inst(
        models_loaded,
        instrument_meter:create_gauge(
            M,
            <<"barrel_inference_models_loaded">>,
            #{description => <<"Models currently loaded">>}
        )
    ),
    ok.

%%====================================================================
%% Hot-path helpers
%%====================================================================

record_request(Endpoint, Model, Status, DurationSec) ->
    Inst = inst(requests_total),
    instrument_meter:add(
        Inst,
        1,
        #{endpoint => Endpoint, model => Model, status => Status}
    ),
    observe_request_duration(Endpoint, Model, DurationSec).

observe_request_duration(Endpoint, Model, DurationSec) ->
    instrument_meter:record(
        inst(request_duration),
        DurationSec,
        #{endpoint => Endpoint, model => Model}
    ).

observe_prefill(Model, DurationSec) ->
    instrument_meter:record(
        inst(prefill_duration),
        DurationSec,
        #{model => Model}
    ).
observe_engine_admit(Model, Op, DurationSec) ->
    instrument_meter:record(
        inst(engine_admit_duration),
        DurationSec,
        #{model => Model, op => Op}
    ).

observe_generation_tps(Model, TokensPerSec) ->
    instrument_meter:record(
        inst(gen_tps),
        TokensPerSec,
        #{model => Model}
    ).

inc_completion_tokens(Model, N) when is_integer(N), N >= 0 ->
    instrument_meter:add(inst(completion_tokens_total), N, #{model => Model}).

inc_prompt_tokens(Model, N) when is_integer(N), N >= 0 ->
    instrument_meter:add(inst(prompt_tokens_total), N, #{model => Model}).

inc_cache_hit(Model, Kind) when Kind =:= exact; Kind =:= partial; Kind =:= cold ->
    instrument_meter:add(
        inst(cache_hits_total),
        1,
        #{model => Model, kind => Kind}
    ).

inc_pool_exhausted(Model) ->
    instrument_meter:add(inst(pool_exhausted_total), 1, #{model => Model}).

inc_queue_dropped(Model, Reason) when Reason =:= timeout; Reason =:= full ->
    instrument_meter:add(
        inst(queue_dropped_total),
        1,
        #{model => Model, reason => Reason}
    ).

set_queue_depth(Model, Depth) when is_integer(Depth), Depth >= 0 ->
    instrument_meter:record(inst(queue_depth), Depth, #{model => Model}).

inc_active_streams(Model) ->
    instrument_meter:add(inst(active_streams), 1, #{model => Model}).

dec_active_streams(Model) ->
    instrument_meter:add(inst(active_streams), -1, #{model => Model}).

set_models_loaded(N) when is_integer(N), N >= 0 ->
    instrument_meter:record(inst(models_loaded), N, #{}).

%%====================================================================
%% Cache stats projection
%%====================================================================

%% Called from /metrics just before instrument_prometheus:format/0.
%% Reads barrel_inference:counters/0 (a map of cache stats) and projects the
%% ones we care about into Prometheus counters. barrel_inference already
%% exports counters/0 in v0.1.0.
update_cache_gauges() ->
    case catch barrel_inference:counters() of
        {'EXIT', _} ->
            ok;
        Map when is_map(Map) ->
            ExactNew = maps:get(cache_exact_hits, Map, 0),
            PartialNew = maps:get(cache_partial_hits, Map, 0),
            ColdNew = maps:get(cache_cold_misses, Map, 0),
            project_delta(<<"_global">>, exact, ExactNew),
            project_delta(<<"_global">>, partial, PartialNew),
            project_delta(<<"_global">>, cold, ColdNew),
            ok;
        _ ->
            ok
    end.

project_delta(Model, Kind, NewTotal) ->
    Key = {?MODULE, cache_seen, Model, Kind},
    Prev = persistent_term:get(Key, 0),
    Delta = NewTotal - Prev,
    case Delta > 0 of
        true ->
            persistent_term:put(Key, NewTotal),
            instrument_meter:add(
                inst(cache_hits_total),
                Delta,
                #{model => Model, kind => Kind}
            );
        false ->
            ok
    end.

%%====================================================================
%% persistent_term helpers
%%====================================================================

put_inst(Key, Inst) -> persistent_term:put({?MODULE, Key}, Inst).
inst(Key) -> persistent_term:get({?MODULE, Key}).
