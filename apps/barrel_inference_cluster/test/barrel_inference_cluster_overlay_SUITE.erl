%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_overlay_SUITE).
-moduledoc """
Gated multi-node test for the facade's remote dispatch path.

Skipped unless `BARREL_CLUSTER_OVERLAY` is set, because it spins up a peer node.
It validates the data plane — that a routed call reaches the chosen peer via
`erpc` and that errors come back tagged with the peer — using plain distribution
(not the mycelium overlay, which is exercised by a real 3-node deployment). The
peer hosts no model, so `model_info/1` on it resolves to a tagged cluster error,
proving the call was dispatched remotely rather than served locally.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_call_routes_to_peer/1]).

-define(PEERS, barrel_inference_cluster_peers).

all() ->
    [remote_call_routes_to_peer].

init_per_suite(Config) ->
    case os:getenv("BARREL_CLUSTER_OVERLAY") of
        false ->
            {skip, "set BARREL_CLUSTER_OVERLAY=1 to run the multi-node suite"};
        _ ->
            ok = ensure_distributed(),
            %% Unlinked: start_link would tie the peer to the transient
            %% init_per_suite process, killing it before end_per_suite.
            {ok, Peer, Node} = peer:start(#{
                name => peer:random_name(),
                args => ["-pa" | code:get_path()]
            }),
            application:set_env(barrel_inference_cluster, enabled, false),
            {ok, StatePid} = barrel_inference_cluster_state:start_link(),
            true = unlink(StatePid),
            [{peer, Peer}, {peer_node, Node}, {state_pid, StatePid} | Config]
    end.

end_per_suite(Config) ->
    case proplists:get_value(peer, Config) of
        undefined -> ok;
        Peer -> catch peer:stop(Peer)
    end,
    case proplists:get_value(state_pid, Config) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid)
    end,
    ok.

remote_call_routes_to_peer(Config) ->
    Node = proplists:get_value(peer_node, Config),
    %% Inject the peer as the sole host of the model, so the facade must route
    %% a per-model introspection call to it.
    ets:delete_all_objects(?PEERS),
    true = ets:insert(?PEERS, {Node, #{models => #{<<"m">> => #{load => 1.0}}, srtt => 1}}),
    Result = barrel_inference_cluster:model_info(<<"m">>),
    %% The peer has no such model loaded, so the runtime call fails there and the
    %% facade tags it with the peer node — confirming remote dispatch.
    case Result of
        {error, {cluster, Node, _}} -> ok;
        Other -> ct:fail({unexpected, Other})
    end.

%% --- helpers ---------------------------------------------------------------

ensure_distributed() ->
    case node() of
        nonode@nohost ->
            {ok, _} = net_kernel:start([?MODULE, shortnames]),
            ok;
        _ ->
            ok
    end.
