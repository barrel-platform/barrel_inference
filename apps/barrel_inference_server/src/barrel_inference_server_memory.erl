%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_memory).
-moduledoc """
Memory-aware model loading.

Before a model loads, estimate its resident footprint (weights +
KV cache) and compare it against currently-available memory. If it
would not fit, unload the least-recently-active idle model and retry;
if nothing is idle, reject with `model_would_oom` rather than letting
llama.cpp OOM the box.

The footprint estimate is best-effort and deliberately conservative
on the side of *not* spuriously rejecting: weights come from the GGUF
file size, KV from the GGUF attention dimensions (grouped-query aware,
so the cache is sized on `head_count_kv`, not the query head count).
When the KV dimensions cannot be read the KV term is dropped and the
configured margin absorbs the slack.

The available-memory reading is the most restrictive of every probe
that reports a sane number: the GPU VRAM probe (`barrel_inference:vram_info/0`)
on a GPU build, and the system-memory probe
(`barrel_inference_pressure_system:sample/0`) which is authoritative on
unified-memory hosts. Both account for already-loaded models, so the
estimate only has to size the new model.

Configuration (`barrel_inference_server` app env):

- `memory_aware_loading` (boolean, default `false`) - master switch.
  Opt-in: the footprint-vs-free-memory comparison is approximate
  (mmapped weights are not all resident, free memory fluctuates), so
  it is left off by default and enabled on memory-bound multi-model
  deployments. Mirrors the pressure scheduler, which is also off by
  default.
- `model_load_memory_margin_b` (non_neg_integer, default 1 GiB) -
  headroom kept free above the estimate.

The eviction decision (`plan_eviction/4`) and the unload loop
(`make_room/3`) are split from the side effects: `make_room/3` takes
an injectable `world()` of probe/candidate/unload closures so the
policy is unit-testable without a live engine.
""".

-export([
    enabled/0,
    margin_b/0,
    estimate_footprint_b/1,
    kv_cache_b/1,
    available_b/0,
    plan_eviction/4,
    make_room/3,
    idle_models/0,
    wait_unloaded/1
]).

-export_type([world/0]).

-ifdef(TEST).
-export([idle_from_status/1]).
-endif.

-define(APP, barrel_inference_server).
%% f16 KV cells (type_k / type_v default; KV quantisation is unwired).
-define(KV_ELEM_BYTES, 2).
-define(DEFAULT_MARGIN_B, 1073741824).
%% Bound on unload rounds; a degenerate world can't spin forever.
-define(MAX_ROUNDS, 16).
%% Bounded poll waiting for an unloaded model's gen_statem to clear the
%% registry before re-checking the fit (50 * 20 ms = 1 s).
-define(UNLOAD_WAIT_ROUNDS, 50).
-define(UNLOAD_WAIT_MS, 20).

%% Side effects make_room/3 needs, injectable for tests.
-type world() :: #{
    available := fun(() -> {ok, non_neg_integer()} | unknown),
    candidates := fun(([binary()]) -> [{binary(), integer()}]),
    unload := fun((binary()) -> ok)
}.

%% =============================================================================
%% Configuration
%% =============================================================================

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(?APP, memory_aware_loading, false) of
        true -> true;
        _ -> false
    end.

-spec margin_b() -> non_neg_integer().
margin_b() ->
    case application:get_env(?APP, model_load_memory_margin_b, ?DEFAULT_MARGIN_B) of
        N when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_MARGIN_B
    end.

%% =============================================================================
%% Footprint estimate
%% =============================================================================

%% Estimate the resident bytes a model loaded with `Config` will hold:
%% mmapped weights (GGUF file size) plus the f16 KV cache at the
%% configured context window. Reads only the GGUF header (cheap).
-spec estimate_footprint_b(map()) -> non_neg_integer().
estimate_footprint_b(Config) ->
    Path = model_path(Config),
    weights_b(Path) + kv_b(Path, n_ctx(Config)).

%% Mmapped weights are the on-disk GGUF size.
weights_b(undefined) ->
    0;
weights_b(Path) ->
    case filelib:file_size(Path) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

kv_b(undefined, _NCtx) ->
    0;
kv_b(_Path, NCtx) when not is_integer(NCtx); NCtx =< 0 ->
    0;
kv_b(Path, NCtx) ->
    case kv_dims(Path) of
        {NLayers, NKvHead, HeadDimSum} ->
            kv_cache_b(#{
                n_ctx => NCtx,
                n_layers => NLayers,
                n_kv_head => NKvHead,
                head_dim_sum => HeadDimSum,
                elem_bytes => ?KV_ELEM_BYTES
            });
        unknown ->
            0
    end.

%% KV bytes for the whole context: every layer stores K and V for each
%% KV head across all positions. `head_dim_sum` is key_length +
%% value_length (per KV head), so K and V are both counted.
-spec kv_cache_b(map()) -> non_neg_integer().
kv_cache_b(#{
    n_ctx := NCtx,
    n_layers := NLayers,
    n_kv_head := NKvHead,
    head_dim_sum := HeadDimSum,
    elem_bytes := ElemBytes
}) ->
    NCtx * NLayers * NKvHead * HeadDimSum * ElemBytes.

%% {NLayers, NKvHead, HeadDimSum} | unknown. Derived from GGUF
%% attention metadata; grouped-query attention sizes the cache on
%% head_count_kv, falling back to head_count for plain MHA.
kv_dims(Path) ->
    case barrel_inference_server_gguf:read_metadata(Path) of
        {ok, M} -> dims_from_meta(M);
        _ -> unknown
    end.

dims_from_meta(M) ->
    NLayers = barrel_inference_server_gguf:block_count(M),
    NHead = barrel_inference_server_gguf:head_count(M),
    NKvHead = default_int(barrel_inference_server_gguf:head_count_kv(M), NHead),
    NEmbd = barrel_inference_server_gguf:embedding_length(M),
    case {pos(NLayers), pos(NKvHead), head_dim_sum(M, NEmbd, NHead)} of
        {true, true, Sum} when is_integer(Sum), Sum > 0 ->
            {NLayers, NKvHead, Sum};
        _ ->
            unknown
    end.

%% key_length + value_length per KV head. Prefer the explicit GGUF
%% fields; otherwise derive head_dim = embedding_length / head_count
%% and use it for both K and V.
head_dim_sum(M, NEmbd, NHead) ->
    KLen = barrel_inference_server_gguf:key_length(M),
    VLen = barrel_inference_server_gguf:value_length(M),
    case {KLen, VLen} of
        {K, V} when is_integer(K), K > 0, is_integer(V), V > 0 ->
            K + V;
        _ when is_integer(NEmbd), NEmbd > 0, is_integer(NHead), NHead > 0 ->
            D = NEmbd div NHead,
            2 * D;
        _ ->
            undefined
    end.

model_path(Config) ->
    case maps:get(model_path, Config, undefined) of
        P when is_list(P); is_binary(P) -> P;
        _ -> undefined
    end.

n_ctx(Config) ->
    case maps:get(context_opts, Config, #{}) of
        Opts when is_map(Opts) -> maps:get(n_ctx, Opts, maps:get(context_size, Config, 0));
        _ -> maps:get(context_size, Config, 0)
    end.

%% =============================================================================
%% Available memory
%% =============================================================================

%% Most restrictive free-byte reading across every probe that returns
%% a sane number. `unknown` when no probe works, in which case the
%% caller does not gate the load (we never block a load we cannot
%% measure).
-spec available_b() -> {ok, non_neg_integer()} | unknown.
available_b() ->
    case [A || {ok, A} <- [vram_probe(), system_probe()]] of
        [] -> unknown;
        As -> {ok, lists:min(As)}
    end.

vram_probe() ->
    try barrel_inference:vram_info() of
        {ok, #{free_b := F, total_b := T}} when
            is_integer(F), F > 0, is_integer(T), T > 0
        ->
            {ok, F};
        _ ->
            none
    catch
        _:_ -> none
    end.

system_probe() ->
    try barrel_inference_pressure_system:sample() of
        {Used, Total} when is_integer(Used), is_integer(Total), Total > 0 ->
            {ok, max(Total - Used, 0)};
        _ ->
            none
    catch
        _:_ -> none
    end.

%% =============================================================================
%% Eviction policy
%% =============================================================================

%% Pure decision for one round. `Candidates` are idle (active = 0)
%% loaded models as `{ModelId, LastActiveMs}`.
-spec plan_eviction(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    [{binary(), integer()}]
) ->
    load | reject | {evict, binary()}.
plan_eviction(EstimateB, AvailB, MarginB, _Candidates) when EstimateB + MarginB =< AvailB ->
    load;
plan_eviction(_EstimateB, _AvailB, _MarginB, []) ->
    reject;
plan_eviction(_EstimateB, _AvailB, _MarginB, Candidates) ->
    {evict, victim(Candidates)}.

%% Least-recently-active idle model.
victim(Candidates) ->
    {Id, _Ms} = hd(lists:keysort(2, Candidates)),
    Id.

%% =============================================================================
%% Unload loop
%% =============================================================================

%% Ensure `EstimateB` fits, unloading idle models if needed. Returns
%% `ok` to proceed with the load or `{error, model_would_oom}` when it
%% cannot be made to fit.
-spec make_room(binary(), non_neg_integer(), world()) ->
    ok | {error, model_would_oom}.
make_room(ModelId, EstimateB, World) ->
    make_room(ModelId, EstimateB, World, [], ?MAX_ROUNDS).

make_room(_ModelId, _EstimateB, _World, _Unloaded, 0) ->
    {error, model_would_oom};
make_room(ModelId, EstimateB, World, Unloaded, Rounds) ->
    #{available := AvailFn, candidates := CandFn, unload := UnloadFn} = World,
    case AvailFn() of
        unknown ->
            ok;
        {ok, AvailB} ->
            case plan_eviction(EstimateB, AvailB, margin_b(), CandFn(Unloaded)) of
                load ->
                    ok;
                reject ->
                    {error, model_would_oom};
                {evict, Victim} ->
                    ok = UnloadFn(Victim),
                    make_room(ModelId, EstimateB, World, [Victim | Unloaded], Rounds - 1)
            end
    end.

%% =============================================================================
%% Idle models (shared by the loader fit-check and the pressure evictor)
%% =============================================================================

%% Loaded models with no in-flight request, least-recently-active first,
%% as `{ModelId, LastActiveMs}`. A zero-active entry is a snapshot; the
%% caller must re-check atomically at unload time (the keepalive
%% `unload_idle_sync/1` does this) to avoid unloading a model whose
%% request began after the snapshot.
-spec idle_models() -> [{binary(), non_neg_integer()}].
idle_models() ->
    Loaded = [E || E <- safe_keepalive_status(), loaded(maps:get(model, E, <<>>))],
    idle_from_status(Loaded).

%% Pure inner filter: keep zero-active entries, return them
%% least-recently-active first. Split out so the active filter + ordering
%% is unit-testable without keepalive/registry IO.
-spec idle_from_status([map()]) -> [{binary(), non_neg_integer()}].
idle_from_status(Status) ->
    Idle = [{Id, maps:get(last_active_ms, E, 0)} || E = #{model := Id, active := 0} <- Status],
    lists:keysort(2, Idle).

%% Bounded poll until an unloaded model's gen_statem clears the registry.
%% The *_sync unloads block on terminate_child, but the registry row is
%% cleared by an async 'DOWN', so this defeats a unload/load memory race
%% and lets `/api/ps` reflect the unload immediately.
-spec wait_unloaded(binary()) -> ok | timeout.
wait_unloaded(ModelId) ->
    wait_unloaded(ModelId, ?UNLOAD_WAIT_ROUNDS).

wait_unloaded(_Id, 0) ->
    timeout;
wait_unloaded(Id, N) ->
    case barrel_inference_registry:whereis_name(Id) of
        undefined ->
            ok;
        Pid ->
            case is_process_alive(Pid) of
                false ->
                    ok;
                true ->
                    timer:sleep(?UNLOAD_WAIT_MS),
                    wait_unloaded(Id, N - 1)
            end
    end.

safe_keepalive_status() ->
    try barrel_inference_server_keepalive:status() of
        L when is_list(L) -> L
    catch
        _:_ -> []
    end.

loaded(Id) ->
    barrel_inference_registry:whereis_name(Id) =/= undefined.

%% =============================================================================
%% Internal
%% =============================================================================

pos(N) when is_integer(N), N > 0 -> true;
pos(_) -> false.

default_int(N, _Default) when is_integer(N), N > 0 -> N;
default_int(_, Default) -> Default.
