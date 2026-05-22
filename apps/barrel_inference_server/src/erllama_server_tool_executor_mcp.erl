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
%%% The catalog entry carries the namespaced tool name and the
%%% separator in the spec, which arrive here as `Ctx.config'. Execution
%%% routes through `barrel_mcp_agent:call_tool/3', which dispatches to
%%% the owning MCP server, and the MCP result is normalised to the
%%% compact shape the loop folds back into the conversation.
-module(erllama_server_tool_executor_mcp).

-export([execute/2]).

-define(DEFAULT_SEP, <<"__">>).

-spec execute(map(), map()) -> {ok, map()} | {error, term()}.
execute(Args, Ctx) when is_map(Args) ->
    Config = maps:get(config, Ctx, #{}),
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
