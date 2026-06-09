-module(barrel_inference_server_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 30
    },
    {ok, CacheRoot} = barrel_inference_server_fetch:cache_root(),
    KvDir = filename:join(CacheRoot, "kv_cache"),
    ok = filelib:ensure_path(KvDir),
    Children = [
        #{
            id => barrel_inference_server_disk_cache,
            start =>
                {barrel_inference_cache_disk_srv, start_link, [
                    barrel_inference_server_disk_cache, KvDir
                ]},
            type => worker,
            shutdown => 5000
        },
        #{
            id => barrel_inference_server_registry,
            start => {barrel_inference_server_registry, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_config,
            start => {barrel_inference_server_config, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_session_state,
            start => {barrel_inference_server_session_state, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_response_store,
            start => {barrel_inference_server_response_store, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_mcp,
            start => {barrel_inference_server_mcp, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_loaders_sup,
            start => {barrel_inference_server_loaders_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => barrel_inference_server_queues_sup,
            start => {barrel_inference_server_queues_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => barrel_inference_server_fetch_sup,
            start => {barrel_inference_server_fetch_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => barrel_inference_server_fetch_srv,
            start => {barrel_inference_server_fetch_srv, start_link, []},
            type => worker,
            shutdown => 5000
        },

        %% Per-pull coordinators. Owns fetch + manifest persistence
        %% independent of the HTTP handler, so a completed download
        %% always registers. Depends on fetch_sup/fetch_srv, so it sits
        %% after them in this rest_for_one list.
        #{
            id => barrel_inference_server_pull_sup,
            start => {barrel_inference_server_pull_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => barrel_inference_server_keepalive,
            start => {barrel_inference_server_keepalive, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => barrel_inference_server_listener_mon,
            start => {barrel_inference_server_listener_mon, start_link, []},
            type => worker,
            shutdown => 5000
        }
    ],
    {ok, {SupFlags, Children}}.
