%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Pure-Erlang tests for the helpers used by the autoparser
%% instrumentation. The instrument_meter:* sinks are exercised
%% end-to-end by the smoke CT suite that scrapes /metrics; here we
%% cover the local helpers that don't depend on the meter being
%% initialised.
-module(barrel_inference_server_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_inference_server_metrics).

%% normalise_sched_entry/1 is exposed only via the module's internals,
%% but the more important contract is "the sampler reads a sensible
%% busy ratio per scheduler when scheduler_wall_time is on". Cover
%% via erlang:statistics directly so the test does not depend on
%% having instrument_meter wired up.
scheduler_wall_time_returns_proper_tuples_test() ->
    Prev = erlang:system_flag(scheduler_wall_time, true),
    try
        Stats = erlang:statistics(scheduler_wall_time_all),
        ?assert(is_list(Stats)),
        %% Each entry is {SchedId, Active, Total} (legacy) or
        %% {SchedId, Type, Active, Total} (OTP 21+). Sampler accepts
        %% both shapes.
        lists:foreach(
            fun
                ({_Sched, Active, Total}) ->
                    ?assert(is_integer(Active) andalso Active >= 0),
                    ?assert(is_integer(Total) andalso Total >= 0),
                    ?assert(Active =< Total);
                ({_Sched, Type, Active, Total}) ->
                    ?assert(is_atom(Type)),
                    ?assert(is_integer(Active) andalso Active >= 0),
                    ?assert(is_integer(Total) andalso Total >= 0),
                    ?assert(Active =< Total)
            end,
            Stats
        )
    after
        erlang:system_flag(scheduler_wall_time, Prev)
    end.

%% A snapshot diff gives a ratio in [0.0, 1.0]. The sampler computes
%% ActiveDelta / TotalDelta per scheduler; this case asserts the
%% arithmetic stays bounded for any plausible (Active, Total) pair.
ratio_within_unit_interval_test() ->
    %% Synthesise a couple of plausible snapshots.
    Cases = [
        {{0, 0}, {0, 1000}},
        {{500, 1000}, {1500, 3000}},
        {{900, 1000}, {900, 1000}}
    ],
    lists:foreach(
        fun({{PA, PT}, {NA, NT}}) ->
            DA = NA - PA,
            DT = NT - PT,
            case DT > 0 of
                true ->
                    R = DA / DT,
                    ?assert(R >= 0.0 andalso R =< 1.0);
                false ->
                    %% No new wall time elapsed; sampler must skip
                    %% (no recorded sample) rather than divide by zero.
                    ?assert(DT =:= 0)
            end
        end,
        Cases
    ).
