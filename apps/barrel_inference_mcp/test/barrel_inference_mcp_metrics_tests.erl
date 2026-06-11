%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
-module(barrel_inference_mcp_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

sample() ->
    <<
        "# HELP barrel_inference_models_loaded Models loaded\n"
        "# TYPE barrel_inference_models_loaded gauge\n"
        "barrel_inference_models_loaded 2\n"
        "barrel_inference_queue_depth{model=\"llama3:8b\"} 0\n"
        "barrel_inference_active_streams{model=\"llama3:8b\"} 1\n"
        "barrel_inference_resident_bytes{model=\"llama3:8b\"} 4600000000\n"
        "barrel_inference_pool_exhausted_total{model=\"llama3:8b\"} 0\n"
        "barrel_inference_cache_hits_total{model=\"llama3:8b\",kind=\"exact\"} 5\n"
        "barrel_inference_cache_hits_total{model=\"llama3:8b\",kind=\"cold\"} 3\n"
        "barrel_inference_generation_tokens_per_second_sum{model=\"llama3:8b\"} 77.4\n"
        "barrel_inference_generation_tokens_per_second_count{model=\"llama3:8b\"} 2\n"
        "other_metric_we_ignore 99\n"
    >>.

digest_test() ->
    D = barrel_inference_mcp_metrics:digest(sample()),
    ?assertEqual(2, maps:get(models_loaded, D)),
    M = maps:get(<<"llama3:8b">>, maps:get(per_model, D)),
    ?assertEqual(0, maps:get(queue_depth, M)),
    ?assertEqual(1, maps:get(active_streams, M)),
    ?assertEqual(4600000000, maps:get(resident_bytes, M)),
    ?assertEqual(0, maps:get(pool_exhausted_total, M)),
    ?assertEqual(#{<<"exact">> => 5, <<"cold">> => 3}, maps:get(cache, M)),
    ?assertEqual(38.7, maps:get(tokens_per_second_avg, M)),
    ?assertNot(maps:is_key(tps_sum, M)),
    ?assertNot(maps:is_key(tps_count, M)).

ignores_non_barrel_test() ->
    Samples = barrel_inference_mcp_metrics:parse(sample()),
    Names = [N || {N, _, _} <- Samples],
    ?assertNot(lists:member(<<"other_metric_we_ignore">>, Names)).
