%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Shared types for the cluster facade. `#candidate{}` is the routing input
%% the router scores; `barrel_inference_cluster_state` produces it from the
%% mycelium service registry + runtime introspection, tests build it directly.

-record(candidate, {
    node :: node(),
    %% Does this node currently host the requested model (loaded)?
    hosts_model = false :: boolean(),
    %% Free-capacity fraction in [0.0, 1.0]; 0.0 = saturated (no admission).
    load = 0.0 :: float(),
    %% Locality score in [0.0, 1.0]; 1.0 = local node, then zone match, then
    %% an SRTT-decay bucket. Derived from operator zone tags + path stats,
    %% never raw IPs.
    locality = 0.0 :: float(),
    %% May this node load the model on a cold spill?
    allow_cold_load = false :: boolean()
}).
