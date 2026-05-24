%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Precedence for the shared n_seq_max resolver that couples the engine
%% seq pool and the server's admission concurrency:
%%   parameters.num_seq_max > loader.n_seq_max > default(4).
-module(barrel_inference_server_n_seq_max_tests).

-include_lib("eunit/include/eunit.hrl").

resolve(M) -> barrel_inference_server_models:resolve_n_seq_max(M).

default_when_absent_test() ->
    ?assertEqual(4, resolve(#{})),
    ?assertEqual(4, resolve(#{<<"loader">> => #{}, <<"parameters">> => #{}})).

loader_value_used_test() ->
    ?assertEqual(2, resolve(#{<<"loader">> => #{<<"n_seq_max">> => 2}})).

parameters_override_loader_test() ->
    M = #{
        <<"loader">> => #{<<"n_seq_max">> => 2},
        <<"parameters">> => #{<<"num_seq_max">> => 8}
    },
    ?assertEqual(8, resolve(M)).

parameters_override_default_test() ->
    ?assertEqual(8, resolve(#{<<"parameters">> => #{<<"num_seq_max">> => 8}})).

invalid_falls_back_to_default_test() ->
    ?assertEqual(4, resolve(#{<<"loader">> => #{<<"n_seq_max">> => 0}})),
    ?assertEqual(4, resolve(#{<<"loader">> => #{<<"n_seq_max">> => <<"nope">>}})).
