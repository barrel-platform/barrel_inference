%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_metrics).
-moduledoc """
Cluster routing metrics, mirroring `barrel_inference_server_metrics` conventions:
an `instrument` meter, durations in seconds (`*_duration_seconds` histograms),
counters suffixed `*_total`. They share the VM's `instrument` registry, so the
server's existing `/metrics` endpoint surfaces them once a node is clustered.

`init/0` is best-effort: if the `instrument` application is not running (e.g. a
unit test that starts only the state server) it no-ops, and every record helper
no-ops when its instrument is absent.
""".

-export([init/0]).
-export([inc_route/1, observe_remote/2, inc_remote_error/1, set_peers/1]).

-define(METER_NAME, <<"barrel_inference_cluster">>).
-define(LATENCY_BUCKETS, [
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
]).

-spec init() -> ok.
init() ->
    try
        create_instruments(instrument_meter:get_meter(?METER_NAME))
    catch
        Class:Reason ->
            logger:debug(
                "[barrel_inference_cluster] metrics init skipped (~p:~p)",
                [Class, Reason]
            ),
            ok
    end.

create_instruments(M) ->
    put_inst(
        routes,
        ctr(M, <<"barrel_inference_cluster_routes_total">>, <<"Routing decisions by outcome">>)
    ),
    put_inst(
        remote_duration,
        hist(
            M,
            <<"barrel_inference_cluster_remote_call_duration_seconds">>,
            <<"Remote runtime call latency over the overlay">>
        )
    ),
    put_inst(
        remote_errors,
        ctr(
            M,
            <<"barrel_inference_cluster_remote_errors_total">>,
            <<"Failed remote runtime calls by reason">>
        )
    ),
    put_inst(peers, gauge(M, <<"barrel_inference_cluster_peers">>, <<"Known cluster peers">>)),
    ok.

ctr(M, Name, Desc) ->
    instrument_meter:create_counter(M, Name, #{description => Desc}).

hist(M, Name, Desc) ->
    instrument_meter:create_histogram(
        M,
        Name,
        #{description => Desc, unit => <<"s">>, boundaries => ?LATENCY_BUCKETS}
    ).

gauge(M, Name, Desc) ->
    instrument_meter:create_gauge(M, Name, #{description => Desc}).

-spec inc_route(local | remote | no_target) -> ok.
inc_route(Decision) ->
    add(routes, 1, #{decision => Decision}).

-spec observe_remote(atom(), number()) -> ok.
observe_remote(Op, DurationSec) ->
    record(remote_duration, DurationSec, #{op => Op}).

-spec inc_remote_error(term()) -> ok.
inc_remote_error(Reason) ->
    add(remote_errors, 1, #{reason => reason_label(Reason)}).

-spec set_peers(non_neg_integer()) -> ok.
set_peers(N) ->
    record(peers, N, #{}).

%% =============================================================================
%% internal
%% =============================================================================

add(Key, N, Labels) ->
    case inst(Key) of
        undefined -> ok;
        Inst -> instrument_meter:add(Inst, N, Labels)
    end.

record(Key, Value, Labels) ->
    case inst(Key) of
        undefined -> ok;
        Inst -> instrument_meter:record(Inst, Value, Labels)
    end.

%% Keep label cardinality bounded: collapse arbitrary error terms to an atom tag.
reason_label(Reason) when is_atom(Reason) -> Reason;
reason_label({Tag, _}) when is_atom(Tag) -> Tag;
reason_label({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_label(_) -> other.

put_inst(Key, Inst) -> persistent_term:put({?MODULE, Key}, Inst).
inst(Key) -> persistent_term:get({?MODULE, Key}, undefined).
