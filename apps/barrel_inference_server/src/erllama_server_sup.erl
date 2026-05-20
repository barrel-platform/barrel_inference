-module(erllama_server_sup).
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
    {ok, CacheRoot} = erllama_server_fetch:cache_root(),
    KvDir = filename:join(CacheRoot, "kv_cache"),
    ok = filelib:ensure_path(KvDir),
    Children = [
        #{
            id => erllama_server_disk_cache,
            start =>
                {erllama_cache_disk_srv, start_link, [erllama_server_disk_cache, KvDir]},
            type => worker,
            shutdown => 5000
        },
        #{
            id => erllama_server_registry,
            start => {erllama_server_registry, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_config,
            start => {erllama_server_config, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_tool_replay,
            start => {erllama_server_tool_replay, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_session_state,
            start => {erllama_server_session_state, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_response_store,
            start => {erllama_server_response_store, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_loaders_sup,
            start => {erllama_server_loaders_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => erllama_server_queues_sup,
            start => {erllama_server_queues_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => erllama_server_fetch_sup,
            start => {erllama_server_fetch_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },

        #{
            id => erllama_server_fetch_srv,
            start => {erllama_server_fetch_srv, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_keepalive,
            start => {erllama_server_keepalive, start_link, []},
            type => worker,
            shutdown => 5000
        },

        #{
            id => erllama_server_listener_mon,
            start => {erllama_server_listener_mon, start_link, []},
            type => worker,
            shutdown => 5000
        }
    ],
    {ok, {SupFlags, Children}}.
