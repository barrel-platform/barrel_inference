%%% MCP client bridge manager.
%%%
%%% Connects barrel_inference_server (as an MCP *client*) to the MCP servers
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
%%%   - rebuild when a server pushes `notifications/<kind>/list_changed'
%%%     (via `barrel_inference_server_mcp_handler' -> `refresh_async/0'), on
%%%     demand via `refresh/0', and on a slow fallback timer.
%%%
%%% Each catalog `server_tools' entry routes back through the mcp
%%% executor: `#{module => barrel_inference_server_tool_executor_mcp, type =>
%%% <<"mcp">>, mcp_name => NsName, separator => Sep}'.
%%%
%%% `mcp_servers' is a list of connect-spec maps, each with an extra
%%% `id': `[#{id => <<"github">>, transport => {http, <<"...">>}, auth
%%% => {bearer, <<"...">>}}]'. Empty (the default) means the bridge is
%%% dormant - the catalog is `{[], #{}}' and nothing is injected.
-module(barrel_inference_server_mcp).
-behaviour(gen_server).

-export([start_link/0, catalog/0, refresh/0, refresh_async/0]).

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
%% list_changed notifications drive refresh; the timer is a slow
%% fallback for servers that don't emit them.
-define(REFRESH_INTERVAL_MS, 300000).

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

%% Like `refresh/0' but non-blocking. The MCP client handler calls this
%% from inside a client process on `list_changed'; a synchronous call
%% would deadlock (the rebuild lists tools back through that client).
-spec refresh_async() -> ok.
refresh_async() ->
    gen_server:cast(?MODULE, refresh).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    persistent_term:put(?CATALOG, {[], #{}}),
    start_clients(application:get_env(barrel_inference_server, mcp_servers, [])),
    %% Clients connect asynchronously; build the catalog shortly after
    %% boot once they reach `ready', then on a periodic timer.
    erlang:send_after(?INITIAL_REFRESH_MS, self(), refresh_tick),
    {ok, []}.

handle_call(refresh, _From, S) ->
    rebuild_catalog(),
    {reply, ok, S};
handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast(refresh, S) ->
    rebuild_catalog(),
    {noreply, S};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(refresh_tick, S) ->
    rebuild_catalog(),
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
    Spec = with_default_handler(maps:remove(id, Entry)),
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

%% Install our notification handler unless the operator set one. The
%% handler forwards `list_changed' to `refresh_async/0' so the catalog
%% tracks runtime tool/resource changes.
with_default_handler(Spec) ->
    case maps:is_key(handler, Spec) of
        true -> Spec;
        false -> Spec#{handler => {barrel_inference_server_mcp_handler, []}}
    end.

rebuild_catalog() ->
    Acc0 = lists:foldl(fun catalog_entry/2, {[], #{}}, safe_list_tools()),
    {ToolsRev, ServerTools} = lists:foldl(fun resource_entries/2, Acc0, connected_servers()),
    persistent_term:put(?CATALOG, {lists:reverse(ToolsRev), ServerTools}).

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
                module => barrel_inference_server_tool_executor_mcp,
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

connected_servers() ->
    try
        barrel_mcp:list_clients()
    catch
        Class:Reason ->
            logger:warning(#{event => mcp_list_clients_failed, error => {Class, Reason}}),
            []
    end.

%% A server that advertises the `resources' capability gets two
%% model-callable meta-tools - `<id>__list_resources' and
%% `<id>__read_resource' - routed to the mcp executor by `server_id' +
%% `kind' (not by a namespaced tool name; these are not `call_tool'
%% targets). Servers without the capability get none.
resource_entries({Id, Pid}, Acc) when is_binary(Id), is_pid(Pid) ->
    case server_has_resources(Pid) of
        true -> add_resource_meta_tools(Id, Acc);
        false -> Acc
    end;
resource_entries(_, Acc) ->
    Acc.

add_resource_meta_tools(Id, {ToolsRev, ServerTools}) ->
    ListName = <<Id/binary, ?SEP/binary, "list_resources">>,
    ReadName = <<Id/binary, ?SEP/binary, "read_resource">>,
    Tools = [
        resource_tool(read_resource, Id, ReadName),
        resource_tool(list_resources, Id, ListName)
        | ToolsRev
    ],
    Specs = ServerTools#{
        ListName => resource_spec(list_resources, Id),
        ReadName => resource_spec(read_resource, Id)
    },
    {Tools, Specs}.

resource_tool(list_resources, Id, Name) ->
    #{
        name => Name,
        description => <<"List resources available from the ", Id/binary, " MCP server.">>,
        schema => #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    };
resource_tool(read_resource, Id, Name) ->
    #{
        name => Name,
        description => <<"Read a resource from the ", Id/binary, " MCP server by its uri.">>,
        schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"uri">>],
            <<"properties">> => #{
                <<"uri">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The resource uri to read.">>
                }
            }
        }
    }.

resource_spec(Kind, Id) ->
    #{
        module => barrel_inference_server_tool_executor_mcp,
        type => <<"mcp">>,
        kind => Kind,
        server_id => Id
    }.

server_has_resources(Pid) ->
    try barrel_mcp_client:server_capabilities(Pid) of
        {ok, Caps} when is_map(Caps) -> maps:is_key(<<"resources">>, Caps);
        _ -> false
    catch
        _:_ -> false
    end.
