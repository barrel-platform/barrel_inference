%%% Executor for MCP-bridged tools.
%%%
%%% Unlike the `lookup_type' built-ins (web_search, ...), MCP tools are
%%% not client-declared types resolved via the executor registry: the
%%% `erllama_server_mcp' manager discovers them from connected MCP
%%% servers and publishes them directly into the tool catalog. So this
%%% module has no `declare/0' and intentionally does not declare the
%%% `erllama_server_tool_executor' behaviour - it only implements
%%% `execute/2', which the agentic loop calls for any `server_tools'
%%% entry whose `module' is this one.
%%%
%%% The catalog entry's spec arrives here as `Ctx.config' and selects
%%% one of two routes via its `kind':
%%%
%%%   - `tool' (default): a namespaced tool call dispatched through
%%%     `barrel_mcp_agent:call_tool/3' to the owning MCP server.
%%%   - `list_resources' / `read_resource': a resource operation on a
%%%     specific server (`server_id'), via that server's client pid.
%%%     barrel_mcp's agent aggregates tools only, so resources go
%%%     straight to `barrel_mcp_client'.
%%%
%%% Either way the MCP result is normalised to the compact shape the
%%% loop folds back into the conversation.
-module(erllama_server_tool_executor_mcp).

-export([execute/2]).

-define(DEFAULT_SEP, <<"__">>).

-spec execute(map(), map()) -> {ok, map()} | {error, term()}.
execute(Args, Ctx) when is_map(Args) ->
    Config = maps:get(config, Ctx, #{}),
    case maps:get(kind, Config, tool) of
        tool -> execute_tool(Args, Config);
        list_resources -> execute_list_resources(Config);
        read_resource -> execute_read_resource(Args, Config)
    end.

execute_tool(Args, Config) ->
    case maps:get(mcp_name, Config, undefined) of
        Name when is_binary(Name) ->
            Sep = maps:get(separator, Config, ?DEFAULT_SEP),
            case barrel_mcp_agent:call_tool(Name, Args, #{separator => Sep}) of
                {ok, Result} -> {ok, normalise(Result)};
                {error, _} = E -> E
            end;
        _ ->
            {error, missing_mcp_name}
    end.

execute_list_resources(Config) ->
    with_client(Config, fun(Pid) ->
        case barrel_mcp_client:list_resources_all(Pid) of
            {ok, Resources} ->
                {ok, #{<<"resources">> => [resource_summary(R) || R <- Resources]}};
            {error, _} = E ->
                E
        end
    end).

execute_read_resource(Args, Config) ->
    case maps:get(<<"uri">>, Args, undefined) of
        Uri when is_binary(Uri) ->
            with_client(Config, fun(Pid) ->
                case barrel_mcp_client:read_resource(Pid, Uri) of
                    {ok, Result} -> {ok, #{<<"content">> => extract_resource_text(Result)}};
                    {error, _} = E -> E
                end
            end);
        _ ->
            {error, missing_uri}
    end.

with_client(Config, Fun) ->
    case maps:get(server_id, Config, undefined) of
        Id when is_binary(Id) ->
            case barrel_mcp_clients:whereis_client(Id) of
                Pid when is_pid(Pid) -> Fun(Pid);
                _ -> {error, unknown_server}
            end;
        _ ->
            {error, missing_server_id}
    end.

resource_summary(R) when is_map(R) ->
    maps:with([<<"uri">>, <<"name">>, <<"description">>, <<"mimeType">>], R).

%% `resources/read' returns `#{contents => [#{uri, mimeType, text|blob}]}'.
%% Join the text blocks (binary blobs are skipped).
extract_resource_text(Result) ->
    Blocks = maps:get(<<"contents">>, Result, []),
    iolist_to_binary(
        lists:join(<<"\n">>, [T || #{<<"text">> := T} <- Blocks, is_binary(T)])
    ).

%% MCP tool results are `#{content => [block], isError => bool,
%% structuredContent => _}'. Fold to text + (optional) structured data
%% + an error flag the model can read.
normalise(Result) ->
    M0 = #{<<"content">> => extract_text(maps:get(<<"content">>, Result, []))},
    M1 =
        case maps:get(<<"structuredContent">>, Result, undefined) of
            undefined -> M0;
            SC -> M0#{<<"structured">> => SC}
        end,
    case maps:get(<<"isError">>, Result, false) of
        true -> M1#{<<"isError">> => true};
        _ -> M1
    end.

extract_text(Blocks) when is_list(Blocks) ->
    iolist_to_binary(
        lists:join(<<"\n">>, [
            T
         || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks, is_binary(T)
        ])
    );
extract_text(_) ->
    <<>>.
