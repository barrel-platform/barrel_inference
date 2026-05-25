%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster).
-moduledoc """
Cluster-wide facade over the `barrel_inference` runtime.

Exports the same functions as the runtime and routes each call to the best node,
so a fleet of nodes behaves as one cluster-wide runtime. In Phase 2 the HTTP
server points its `engine_module` at this module instead of `barrel_inference`.

Routing classes (see the plan):
- **Session-routed** (`infer/4`, `continue/3`, `complete/*`, `prefill_only/*`,
  `cancel/1`, `end_session/2`, `reset_session/2`): pick a replica by sticky
  affinity → locality → load. Async calls (`infer`/`continue`) run remotely via
  `erpc` with the original caller pid, so the peer's runtime streams straight back
  over the mycelium dist link; the returned `Ref` is tracked so `cancel/1` routes
  to the home node.
- **Stateless / per-model** (`apply_chat_template/2`, `tokenize/2`, `embed/2`,
  `model_info/1`, `pending_len/1`, …): run on a node that hosts the model.
- **Node-local** (`load_model/*`, `unload/1`, adapters, `counters/0`, …) and the
  speculative-decode primitives (`draft_tokens/3`, `verify/4`) pass straight
  through to the local runtime. Cluster-wide aggregation of introspection and
  fan-out admin are Phase-2 refinements.

With no peers (or the cluster disabled) every route resolves local, so the facade
is a transparent passthrough to `barrel_inference`.
""".

-include("barrel_inference_cluster.hrl").

%% Session-routed (mode A)
-export([
    infer/4,
    continue/3,
    complete/2,
    complete/3,
    prefill_only/2,
    prefill_only/3,
    cancel/1,
    end_session/2,
    reset_session/2
]).
%% Stateless prep (mode B)
-export([apply_chat_template/2, tokenize/2, detokenize/2, embed/2]).
%% Per-model introspection (mode C)
-export([
    model_info/1,
    status/1,
    pending_len/1,
    phase/1,
    last_cache_hit/1,
    list_cached_prefixes/2,
    queue_depth/1,
    list_adapters/1
]).
%% Aggregate / node-local introspection (mode D)
-export([models/0, list_models/0, queue_depth/0, counters/0, vram_info/0]).
%% Node-local lifecycle (mode E)
-export([
    load_model/1,
    load_model/2,
    unload/1,
    unload_model/1,
    evict/1,
    shutdown/1,
    load_adapter/2,
    unload_adapter/2,
    set_adapter_scale/3
]).
%% Speculative-decode primitives (mode F, future)
-export([draft_tokens/3, verify/4]).
%% Cluster admin / test seam
-export([route/2, node_snapshot/0]).

-type model() :: binary().
-type tokens() :: [non_neg_integer()].
-export_type([model/0, tokens/0]).

%% =============================================================================
%% Mode A — session-routed
%% =============================================================================

-spec infer(model(), tokens(), map(), pid()) -> {ok, reference()} | {error, term()}.
infer(Model, Tokens, Params, CallerPid) ->
    Sid = session_of(Params),
    Node = pick(Model, home(Sid)),
    maybe_record(Sid, Node),
    case is_local(Node) of
        true -> barrel_inference:infer(Model, Tokens, Params, CallerPid);
        false -> remote_async(Node, infer, [Model, Tokens, Params, CallerPid], CallerPid)
    end.

-spec continue(model(), tokens(), map()) -> {ok, reference()} | {error, term()}.
continue(Model, Tokens, Opts) ->
    Sid = session_of(Opts),
    Node = pick(Model, home(Sid)),
    maybe_record(Sid, Node),
    CallerPid = maps:get(caller_pid, Opts, self()),
    case is_local(Node) of
        true -> barrel_inference:continue(Model, Tokens, Opts);
        false -> remote_async(Node, continue, [Model, Tokens, Opts], CallerPid)
    end.

-spec complete(model(), binary()) -> {ok, term()} | {error, term()}.
complete(Model, Bin) ->
    call_sync(pick(Model, undefined), complete, [Model, Bin]).

-spec complete(model(), binary(), map()) -> {ok, term()} | {error, term()}.
complete(Model, Bin, Opts) ->
    Sid = session_of(Opts),
    Node = pick(Model, home(Sid)),
    maybe_record(Sid, Node),
    call_sync(Node, complete, [Model, Bin, Opts]).

-spec prefill_only(model(), binary()) -> term().
prefill_only(Model, Bin) ->
    call_sync(pick(Model, undefined), prefill_only, [Model, Bin]).

-spec prefill_only(model(), binary(), map()) -> term().
prefill_only(Model, Bin, Opts) ->
    Sid = session_of(Opts),
    Node = pick(Model, home(Sid)),
    maybe_record(Sid, Node),
    call_sync(Node, prefill_only, [Model, Bin, Opts]).

-spec cancel(reference()) -> ok.
cancel(Ref) ->
    case barrel_inference_cluster_state:lookup_ref(Ref) of
        {ok, Node} when Node =/= node() ->
            barrel_inference_cluster_state:untrack_ref(Ref),
            _ = (catch erpc:cast(Node, barrel_inference, cancel, [Ref])),
            ok;
        {ok, _Local} ->
            barrel_inference_cluster_state:untrack_ref(Ref),
            barrel_inference:cancel(Ref);
        error ->
            barrel_inference:cancel(Ref)
    end.

-spec end_session(model(), binary()) -> term().
end_session(Model, SessionId) ->
    call_sync(session_node(SessionId), end_session, [Model, SessionId]).

-spec reset_session(model(), binary()) -> term().
reset_session(Model, SessionId) ->
    call_sync(session_node(SessionId), reset_session, [Model, SessionId]).

%% =============================================================================
%% Mode B — stateless prep (run on a model-bearing node)
%% =============================================================================

-spec apply_chat_template(model(), term()) -> term().
apply_chat_template(Model, Req) ->
    call_sync(hosting(Model), apply_chat_template, [Model, Req]).

-spec tokenize(model(), binary()) -> term().
tokenize(Model, Bin) ->
    call_sync(hosting(Model), tokenize, [Model, Bin]).

-spec detokenize(model(), tokens()) -> term().
detokenize(Model, Toks) ->
    call_sync(hosting(Model), detokenize, [Model, Toks]).

-spec embed(model(), tokens()) -> term().
embed(Model, Toks) ->
    call_sync(hosting(Model), embed, [Model, Toks]).

%% =============================================================================
%% Mode C — per-model introspection (target a hosting node)
%% =============================================================================

-spec model_info(model()) -> term().
model_info(Model) -> call_sync(hosting(Model), model_info, [Model]).

-spec status(model()) -> term().
status(Model) -> call_sync(hosting(Model), status, [Model]).

-spec pending_len(model()) -> term().
pending_len(Model) -> call_sync(hosting(Model), pending_len, [Model]).

-spec phase(model()) -> term().
phase(Model) -> call_sync(hosting(Model), phase, [Model]).

-spec last_cache_hit(model()) -> term().
last_cache_hit(Model) -> call_sync(hosting(Model), last_cache_hit, [Model]).

-spec list_cached_prefixes(model(), tokens()) -> term().
list_cached_prefixes(Model, Toks) ->
    call_sync(hosting(Model), list_cached_prefixes, [Model, Toks]).

-spec queue_depth(model()) -> term().
queue_depth(Model) -> call_sync(hosting(Model), queue_depth, [Model]).

-spec list_adapters(model()) -> term().
list_adapters(Model) -> call_sync(hosting(Model), list_adapters, [Model]).

%% =============================================================================
%% Mode D — aggregate / node-local introspection
%% =============================================================================
%% v1: local passthrough. Cluster-wide aggregation (union of models across nodes
%% for /v1/models, summed counters) lands in Phase 2 when the server consumes it.

-spec models() -> term().
models() -> barrel_inference:models().

-spec list_models() -> term().
list_models() -> barrel_inference:list_models().

-spec queue_depth() -> term().
queue_depth() -> barrel_inference:queue_depth().

-spec counters() -> term().
counters() -> barrel_inference:counters().

-spec vram_info() -> term().
vram_info() -> barrel_inference:vram_info().

%% =============================================================================
%% Mode E — node-local lifecycle (local passthrough)
%% =============================================================================
%% These act on the local node. Cluster-wide load/unload is an explicit admin
%% operation exposed via the CLI, not a silent fan-out of the mirrored API.

%% load_model/1 takes a full config map (not a model id); see the runtime.
-spec load_model(map()) -> term().
load_model(Config) -> barrel_inference:load_model(Config).

-spec load_model(model(), map()) -> term().
load_model(Model, Opts) -> barrel_inference:load_model(Model, Opts).

-spec unload(model()) -> term().
unload(Model) -> barrel_inference:unload(Model).

-spec unload_model(model()) -> term().
unload_model(Model) -> barrel_inference:unload_model(Model).

-spec evict(model()) -> term().
evict(Model) -> barrel_inference:evict(Model).

-spec shutdown(model()) -> term().
shutdown(Model) -> barrel_inference:shutdown(Model).

-spec load_adapter(model(), term()) -> term().
load_adapter(Model, Adapter) -> barrel_inference:load_adapter(Model, Adapter).

-spec unload_adapter(model(), term()) -> term().
unload_adapter(Model, Adapter) -> barrel_inference:unload_adapter(Model, Adapter).

-spec set_adapter_scale(model(), term(), float()) -> term().
set_adapter_scale(Model, Adapter, Scale) ->
    barrel_inference:set_adapter_scale(Model, Adapter, Scale).

%% =============================================================================
%% Mode F — speculative-decode primitives (future; local passthrough)
%% =============================================================================

-spec draft_tokens(term(), term(), term()) -> term().
draft_tokens(A, B, C) -> barrel_inference:draft_tokens(A, B, C).

-spec verify(term(), term(), term(), term()) -> term().
verify(A, B, C, D) -> barrel_inference:verify(A, B, C, D).

%% =============================================================================
%% Cluster admin / test seam
%% =============================================================================

-doc """
Routing decision for `Model` given an affinity key (session home or `undefined`).
Exported so tests can assert local/remote/sticky decisions without dispatching.
""".
-spec route(model(), node() | undefined) -> barrel_inference_cluster_router:decision().
route(Model, Affinity) ->
    Cands = barrel_inference_cluster_state:candidates(Model),
    barrel_inference_cluster_router:route(Cands, #{
        local_node => node(),
        affinity_home => Affinity,
        policy => policy()
    }).

-spec node_snapshot() -> map().
node_snapshot() ->
    barrel_inference_cluster_state:node_snapshot().

%% =============================================================================
%% internal
%% =============================================================================

is_local(Node) -> Node =:= node().

session_of(Map) when is_map(Map) -> maps:get(session_id, Map, undefined);
session_of(_) -> undefined.

home(undefined) ->
    undefined;
home(Sid) ->
    case barrel_inference_cluster_state:affinity_home(Sid) of
        {ok, Node} -> Node;
        none -> undefined
    end.

maybe_record(undefined, _Node) -> ok;
maybe_record(Sid, Node) -> barrel_inference_cluster_state:record_affinity(Sid, Node).

%% Node owning a session (its home), or local if not pinned.
session_node(SessionId) ->
    case home(SessionId) of
        undefined -> node();
        Node -> Node
    end.

%% Resolve a routing decision to a concrete node, defaulting to local.
pick(Model, Affinity) ->
    Decision = route(Model, Affinity),
    barrel_inference_cluster_metrics:inc_route(decision_label(Decision)),
    case Decision of
        {local} -> node();
        {remote, Node} -> Node;
        {error, no_target} -> node()
    end.

decision_label({local}) -> local;
decision_label({remote, _Node}) -> remote;
decision_label({error, no_target}) -> no_target.

%% A node that currently hosts the model (prefer local), else local.
hosting(Model) ->
    Cands = barrel_inference_cluster_state:candidates(Model),
    case [C || C <- Cands, C#candidate.hosts_model] of
        [] ->
            node();
        Hosting ->
            case lists:keyfind(node(), #candidate.node, Hosting) of
                #candidate{} -> node();
                false -> (hd(Hosting))#candidate.node
            end
    end.

policy() ->
    case application:get_env(barrel_inference_cluster, replica_policy, cache_affinity) of
        custom ->
            application:get_env(barrel_inference_cluster, weights, #{load => 0.2, locality => 0.3});
        Preset ->
            Preset
    end.

call_timeout() ->
    application:get_env(barrel_inference_cluster, call_timeout_ms, 120000).

call_sync(Node, Fun, Args) when Node =:= node() ->
    apply(barrel_inference, Fun, Args);
call_sync(Node, Fun, Args) ->
    case timed_remote(Node, Fun, Args) of
        {ok_result, Result} -> Result;
        {error, _} = Err -> Err
    end.

%% Run an async runtime call (infer/continue) on a peer with the original caller
%% pid; the peer streams back over dist. Track the returned Ref for cancel/reap.
remote_async(Node, Fun, Args, CallerPid) ->
    case timed_remote(Node, Fun, Args) of
        {ok_result, {ok, Ref} = Ok} when is_reference(Ref) ->
            barrel_inference_cluster_state:track_ref(Ref, Node, CallerPid),
            Ok;
        {ok_result, Other} ->
            Other;
        {error, _} = Err ->
            Err
    end.

%% Timed `erpc` to the runtime on a peer; records latency / error metrics.
timed_remote(Node, Fun, Args) ->
    T0 = erlang:monotonic_time(millisecond),
    try erpc:call(Node, barrel_inference, Fun, Args, call_timeout()) of
        Result ->
            Elapsed = (erlang:monotonic_time(millisecond) - T0) / 1000,
            barrel_inference_cluster_metrics:observe_remote(Fun, Elapsed),
            {ok_result, Result}
    catch
        Class:Reason ->
            barrel_inference_cluster_metrics:inc_remote_error(Reason),
            {error, {cluster, Node, {Class, Reason}}}
    end.
