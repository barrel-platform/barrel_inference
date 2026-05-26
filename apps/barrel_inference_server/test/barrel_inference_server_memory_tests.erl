%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_memory_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GB, 1073741824).

%% GGUF value type tags (subset used here).
-define(T_UINT32, 4).
-define(T_STRING, 8).

%% =============================================================================
%% kv_cache_b/1
%% =============================================================================

kv_cache_b_formula_test() ->
    %% n_ctx * n_layers * n_kv_head * (key_len + value_len) * elem_bytes
    %% = 4096 * 4 * 2 * 128 * 2
    ?assertEqual(
        4096 * 4 * 2 * 128 * 2,
        barrel_inference_server_memory:kv_cache_b(#{
            n_ctx => 4096,
            n_layers => 4,
            n_kv_head => 2,
            head_dim_sum => 128,
            elem_bytes => 2
        })
    ).

%% =============================================================================
%% plan_eviction/4
%% =============================================================================

plan_eviction_loads_when_it_fits_test() ->
    ?assertEqual(load, barrel_inference_server_memory:plan_eviction(100, 1000, 0, [])),
    %% Fits exactly at the margin boundary.
    ?assertEqual(load, barrel_inference_server_memory:plan_eviction(100, 1000, 900, [])).

plan_eviction_rejects_when_nothing_idle_test() ->
    ?assertEqual(reject, barrel_inference_server_memory:plan_eviction(800, 1000, 300, [])).

plan_eviction_evicts_least_recently_active_test() ->
    Cands = [{<<"a">>, 300}, {<<"b">>, 50}, {<<"c">>, 200}],
    ?assertEqual(
        {evict, <<"b">>},
        barrel_inference_server_memory:plan_eviction(800, 1000, 300, Cands)
    ).

%% =============================================================================
%% make_room/3 (injected world)
%% =============================================================================

make_room_loads_when_it_fits_test() ->
    set_margin(?GB),
    World = #{
        available => fun() -> {ok, 64 * ?GB} end,
        candidates => fun(_) -> [] end,
        unload => fun(_) -> erlang:error(should_not_unload) end
    },
    ?assertEqual(ok, barrel_inference_server_memory:make_room(<<"new">>, 8 * ?GB, World)).

make_room_fails_open_when_unmeasurable_test() ->
    set_margin(?GB),
    World = #{
        available => fun() -> unknown end,
        candidates => fun(_) -> [{<<"x">>, 1}] end,
        unload => fun(_) -> erlang:error(should_not_unload) end
    },
    ?assertEqual(ok, barrel_inference_server_memory:make_room(<<"new">>, 999 * ?GB, World)).

make_room_rejects_when_nothing_idle_test() ->
    set_margin(?GB),
    World = #{
        available => fun() -> {ok, 1 * ?GB} end,
        candidates => fun(_) -> [] end,
        unload => fun(_) -> ok end
    },
    ?assertEqual(
        {error, model_would_oom},
        barrel_inference_server_memory:make_room(<<"new">>, 8 * ?GB, World)
    ).

make_room_evicts_idle_then_loads_test() ->
    set_margin(?GB),
    erlang:put(unloaded, []),
    World = #{
        %% Too small until one model is unloaded.
        available => fun() ->
            case erlang:get(unloaded) of
                [] -> {ok, 2 * ?GB};
                _ -> {ok, 20 * ?GB}
            end
        end,
        candidates => fun(Unloaded) ->
            case lists:member(<<"victim">>, Unloaded) of
                true -> [];
                false -> [{<<"victim">>, 1}]
            end
        end,
        unload => fun(Id) ->
            erlang:put(unloaded, [Id | erlang:get(unloaded)]),
            ok
        end
    },
    ?assertEqual(ok, barrel_inference_server_memory:make_room(<<"new">>, 5 * ?GB, World)),
    ?assertEqual([<<"victim">>], erlang:get(unloaded)).

%% =============================================================================
%% estimate_footprint_b/1 (weights file size + KV)
%% =============================================================================

estimate_footprint_uses_explicit_kv_dims_test() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen3">>},
        {<<"qwen3.embedding_length">>, ?T_UINT32, 5120},
        {<<"qwen3.block_count">>, ?T_UINT32, 4},
        {<<"qwen3.attention.head_count">>, ?T_UINT32, 40},
        {<<"qwen3.attention.head_count_kv">>, ?T_UINT32, 2},
        {<<"qwen3.attention.key_length">>, ?T_UINT32, 64},
        {<<"qwen3.attention.value_length">>, ?T_UINT32, 64}
    ],
    with_gguf(KVs, fun(Path) ->
        Weights = filelib:file_size(Path),
        Config = #{model_path => Path, context_opts => #{n_ctx => 4096}},
        Kv = 4096 * 4 * 2 * (64 + 64) * 2,
        ?assertEqual(
            Weights + Kv,
            barrel_inference_server_memory:estimate_footprint_b(Config)
        )
    end).

%% No explicit key/value length: head_dim is derived from
%% embedding_length / head_count and used for both K and V.
estimate_footprint_derives_head_dim_test() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"llama">>},
        {<<"llama.embedding_length">>, ?T_UINT32, 4096},
        {<<"llama.block_count">>, ?T_UINT32, 4},
        {<<"llama.attention.head_count">>, ?T_UINT32, 32},
        {<<"llama.attention.head_count_kv">>, ?T_UINT32, 32}
    ],
    with_gguf(KVs, fun(Path) ->
        Weights = filelib:file_size(Path),
        Config = #{model_path => Path, context_opts => #{n_ctx => 2048}},
        HeadDim = 4096 div 32,
        Kv = 2048 * 4 * 32 * (2 * HeadDim) * 2,
        ?assertEqual(
            Weights + Kv,
            barrel_inference_server_memory:estimate_footprint_b(Config)
        )
    end).

%% Unreadable / missing KV dims drop the KV term: weights only.
estimate_footprint_weights_only_when_dims_unknown_test() ->
    KVs = [{<<"general.architecture">>, ?T_STRING, <<"llama">>}],
    with_gguf(KVs, fun(Path) ->
        Weights = filelib:file_size(Path),
        Config = #{model_path => Path, context_opts => #{n_ctx => 4096}},
        ?assertEqual(
            Weights,
            barrel_inference_server_memory:estimate_footprint_b(Config)
        )
    end).

estimate_footprint_zero_without_path_test() ->
    ?assertEqual(0, barrel_inference_server_memory:estimate_footprint_b(#{})).

%% =============================================================================
%% idle_from_status/1 (pure active-filter + recency ordering)
%% =============================================================================

idle_from_status_excludes_busy_and_orders_by_recency_test() ->
    Status = [
        #{model => <<"a">>, active => 0, last_active_ms => 300},
        #{model => <<"b">>, active => 1, last_active_ms => 50},
        #{model => <<"c">>, active => 0, last_active_ms => 100}
    ],
    %% b is busy (excluded); remaining are least-recently-active first.
    ?assertEqual(
        [{<<"c">>, 100}, {<<"a">>, 300}],
        barrel_inference_server_memory:idle_from_status(Status)
    ).

idle_from_status_empty_test() ->
    ?assertEqual([], barrel_inference_server_memory:idle_from_status([])),
    ?assertEqual(
        [],
        barrel_inference_server_memory:idle_from_status([
            #{model => <<"x">>, active => 2, last_active_ms => 1}
        ])
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

set_margin(N) ->
    application:set_env(barrel_inference_server, model_load_memory_margin_b, N).

with_gguf(KVs, Fun) ->
    Path = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "barrel_inference_server_memory_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".gguf"
    ),
    ok = file:write_file(Path, build_gguf(KVs)),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.

build_gguf(KVs) ->
    Body = iolist_to_binary([encode_kv(K, T, V) || {K, T, V} <- KVs]),
    <<"GGUF", 3:32/little, 0:64/little, (length(KVs)):64/little, Body/binary>>.

encode_kv(Key, Type, Value) ->
    <<(encode_string(Key))/binary, Type:32/little, (encode_value(Type, Value))/binary>>.

encode_value(?T_UINT32, V) -> <<V:32/little-unsigned>>;
encode_value(?T_STRING, V) -> encode_string(V).

encode_string(Bin) ->
    <<(byte_size(Bin)):64/little-unsigned, Bin/binary>>.
