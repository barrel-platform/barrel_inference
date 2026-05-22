%%% MCP client bridge manager.
%%%
%%% Connects erllama_server (as an MCP *client*) to the MCP servers
%%% listed in the `mcp_servers' app env, and publishes their tools as
%%% a server-side tool catalog so the agentic continue-loop can call
%%% them. The heavy lifting (transport, JSON-RPC, initialize handshake,
%%% federation, namespacing, routing) lives in `barrel_mcp'; this
%%% module is the thin bridge:
%%%
%%%   - on boot, `barrel_mcp:start_client/2' for each configured server
%%%     (resilient: a server that fails to start is logged and skipped),
%%%   - build a catalog from `barrel_mcp_agent:list_tools/1' - one
%%%     `tool()' (model-facing name + JSON schema) plus one
%%%     `server_tools' entry per MCP tool - and publish it to
%%%     persistent_term for a lock-free read on the request path,
%%%   - rebuild on a timer (and on demand via `refresh/0').
%%%
%%% Each catalog `server_tools' entry routes back through the mcp
%%% executor: `#{module => erllama_server_tool_executor_mcp, type =>
%%% <<"mcp">>, mcp_name => NsName, separator => Sep}'.
%%%
%%% `mcp_servers' is a list of connect-spec maps, each with an extra
%%% `id': `[#{id => <<"github">>, transport => {http, <<"...">>}, auth
%%% => {bearer, <<"...">>}}]'. Empty (the default) means the bridge is
%%% dormant - the catalog is `{[], #{}}' and nothing is injected.
-module(erllama_server_mcp).
-behaviour(gen_server).

-export([start_link/0, catalog/0, refresh/0]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(CATALOG, {?MODULE, catalog}).
-define(SEP, <<"__">>).
-define(INITIAL_REFRESH_MS, 1500).
-define(REFRESH_INTERVAL_MS, 60000).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The current MCP tool catalog: `{Tools, ServerTools}'. Lock-free
%% read; `{[], #{}}' when no servers are configured or none are ready.
-spec catalog() -> {[map()], map()}.
catalog() ->
    persistent_term:get(?CATALOG, {[], #{}}).

%% Rebuild the catalog now (e.g. after a server's tool list changes).
-spec refresh() -> ok.
refresh() ->
    gen_server:call(?MODULE, refresh, 30000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    persistent_term:put(?CATALOG, {[], #{}}),
    start_clients(application:get_env(erllama_server, mcp_servers, [])),
    %% Clients connect asynchronously; build the catalog shortly after
    %% boot once they reach `ready', then on a periodic timer.
    erlang:send_after(?INITIAL_REFRESH_MS, self(), refresh_tick),
    {ok, []}.

handle_call(refresh, _From, S) ->
    do_refresh(),
    {reply, ok, S};
handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast(_, S) ->
    {noreply, S}.

handle_info(refresh_tick, S) ->
    do_refresh(),
    erlang:send_after(?REFRESH_INTERVAL_MS, self(), refresh_tick),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    persistent_term:erase(?CATALOG),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_clients(Servers) when is_list(Servers) ->
    lists:foreach(fun start_client/1, Servers);
start_clients(_) ->
    ok.

start_client(#{id := Id} = Entry) ->
    Spec = maps:remove(id, Entry),
    try barrel_mcp:start_client(Id, Spec) of
        {ok, _Pid} ->
            ok;
        {error, Reason} ->
            logger:warning(#{event => mcp_client_start_failed, id => Id, reason => Reason})
    catch
        Class:CErr ->
            logger:warning(#{
                event => mcp_client_start_crashed, id => Id, error => {Class, CErr}
            })
    end;
start_client(Bad) ->
    logger:warning(#{event => mcp_server_config_invalid, entry => Bad}).

do_refresh() ->
    Tools0 = safe_list_tools(),
    {Tools, ServerTools} = lists:foldl(fun catalog_entry/2, {[], #{}}, Tools0),
    persistent_term:put(?CATALOG, {lists:reverse(Tools), ServerTools}).

safe_list_tools() ->
    try
        barrel_mcp_agent:list_tools(#{separator => ?SEP})
    catch
        Class:Reason ->
            logger:warning(#{event => mcp_list_tools_failed, error => {Class, Reason}}),
            []
    end.

catalog_entry(McpTool, {ToolsRev, ServerTools}) when is_map(McpTool) ->
    case maps:get(<<"name">>, McpTool, undefined) of
        Name when is_binary(Name) ->
            Tool = #{
                name => Name,
                description => maps:get(<<"description">>, McpTool, <<>>),
                schema => maps:get(<<"inputSchema">>, McpTool, #{})
            },
            Spec = #{
                module => erllama_server_tool_executor_mcp,
                type => <<"mcp">>,
                mcp_name => Name,
                separator => ?SEP
            },
            {[Tool | ToolsRev], ServerTools#{Name => Spec}};
        _ ->
            {ToolsRev, ServerTools}
    end;
catalog_entry(_, Acc) ->
    Acc.
