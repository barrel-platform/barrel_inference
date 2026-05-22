%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Boots an in-process barrel_mcp Streamable HTTP server exposing one
%% tool, points the erllama_server_mcp manager at it, and asserts the
%% manager publishes that tool into its catalog. No model needed.
-module(erllama_server_mcp_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [catalog_and_executor].

%% Tool handler registered on the in-process MCP server.
echo_tool(#{<<"text">> := T}) -> T.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo the input text back unchanged">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}
        }
    }),
    Port = free_port(),
    {ok, _} = barrel_mcp_http_stream:start(#{port => Port, session_enabled => true}),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])),
    [{url, Url} | Config].

end_per_suite(_Config) ->
    application:unset_env(erllama_server, mcp_servers),
    ok.

end_per_testcase(_, _Config) ->
    catch gen_server:stop(erllama_server_mcp, normal, 5000),
    catch barrel_mcp:stop_client(<<"t">>),
    application:unset_env(erllama_server, mcp_servers),
    ok.

%% End to end against the in-process server (no model): the manager
%% connects, publishes the catalog, and the mcp executor runs a tool
%% via the catalog's server_tools spec (the same Ctx the loop builds).
catalog_and_executor(Config) ->
    Url = ?config(url, Config),
    application:set_env(erllama_server, mcp_servers, [
        #{id => <<"t">>, transport => {http, Url}}
    ]),
    {ok, _Pid} = erllama_server_mcp:start_link(),
    ok = wait_client_ready(<<"t">>, 50),
    ok = erllama_server_mcp:refresh(),
    {Tools, ServerTools} = erllama_server_mcp:catalog(),
    Names = [maps:get(name, T) || T <- Tools],
    %% Tool name is namespaced `<<ServerId, "__", Name>>`.
    ?assert(lists:member(<<"t__echo">>, Names)),
    Spec = maps:get(<<"t__echo">>, ServerTools),
    ?assertMatch(
        #{module := erllama_server_tool_executor_mcp, mcp_name := <<"t__echo">>}, Spec
    ),
    [Tool] = [T || T <- Tools, maps:get(name, T) =:= <<"t__echo">>],
    ?assert(is_map(maps:get(schema, Tool))),
    %% Run it via the executor with the loop-shaped Ctx.
    Ctx = #{
        model => <<"m">>,
        request_id => <<"r">>,
        session_id => undefined,
        config => maps:without([module, type], Spec)
    },
    {ok, Result} = erllama_server_tool_executor_mcp:execute(
        #{<<"text">> => <<"hello mcp">>}, Ctx
    ),
    ?assertEqual(<<"hello mcp">>, maps:get(<<"content">>, Result)).

%%====================================================================
%% Helpers
%%====================================================================

wait_client_ready(_Id, 0) ->
    {error, not_ready};
wait_client_ready(Id, N) ->
    case barrel_mcp_clients:whereis_client(Id) of
        Pid when is_pid(Pid) ->
            case catch barrel_mcp_client:server_capabilities(Pid) of
                {ok, _} -> ok;
                _ -> retry_ready(Id, N)
            end;
        _ ->
            retry_ready(Id, N)
    end.

retry_ready(Id, N) ->
    timer:sleep(100),
    wait_client_ready(Id, N - 1).

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.
