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
    [catalog_and_executor, list_changed_refresh, stdio_transport, resources_bridge].

%% Tool handler registered on the in-process MCP server.
echo_tool(#{<<"text">> := T}) -> T.

%% Resource handler registered on the in-process MCP server.
greeting_resource(_) -> <<"hello, world">>.

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
    ok = barrel_mcp_registry:reg(resource, <<"greeting">>, ?MODULE, greeting_resource, #{
        name => <<"Greeting">>,
        uri => <<"mem://greeting">>,
        description => <<"Sample greeting resource">>,
        mime_type => <<"text/plain">>
    }),
    Port = free_port(),
    {ok, _} = barrel_mcp_http_stream:start(#{port => Port, session_enabled => true}),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])),
    [{url, Url} | Config].

end_per_suite(_Config) ->
    catch barrel_mcp_registry:unreg(resource, <<"greeting">>),
    application:unset_env(erllama_server, mcp_servers),
    ok.

end_per_testcase(_, _Config) ->
    catch gen_server:stop(erllama_server_mcp, normal, 5000),
    catch barrel_mcp:stop_client(<<"t">>),
    catch barrel_mcp:stop_client(<<"lc">>),
    catch barrel_mcp:stop_client(<<"py">>),
    catch barrel_mcp:stop_client(<<"r">>),
    catch barrel_mcp_registry:unreg(tool, <<"echo2">>),
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

%% A server that adds a tool at runtime broadcasts
%% notifications/tools/list_changed; the manager's client handler kicks
%% an async refresh, so the new tool lands in the catalog without
%% waiting for the fallback timer.
list_changed_refresh(Config) ->
    Url = ?config(url, Config),
    application:set_env(erllama_server, mcp_servers, [
        #{id => <<"lc">>, transport => {http, Url}}
    ]),
    {ok, _Pid} = erllama_server_mcp:start_link(),
    ok = wait_client_ready(<<"lc">>, 50),
    ok = erllama_server_mcp:refresh(),
    {Tools0, _} = erllama_server_mcp:catalog(),
    ?assert(lists:member(<<"lc__echo">>, [maps:get(name, T) || T <- Tools0])),
    ?assertNot(lists:member(<<"lc__echo2">>, [maps:get(name, T) || T <- Tools0])),
    %% Register a second tool on the in-process server: this broadcasts
    %% list_changed to the connected client. No explicit refresh here -
    %% the notification must drive it.
    ok = barrel_mcp_registry:reg(tool, <<"echo2">>, ?MODULE, echo_tool, #{
        description => <<"Second echo">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}
        }
    }),
    ok = wait_catalog_tool(<<"lc__echo2">>, 50).

%% stdio transport against barrel_mcp's Python reference server. Gated
%% on INTEROP_PYTHON (a venv interpreter with the `mcp' package); skips
%% cleanly on the default `rebar3 ct' loop. Proves the manager forwards
%% a `{stdio, _}' connect spec and bridges the spawned server's tools.
stdio_transport(_Config) ->
    case python_or_skip() of
        {skip, _} = Skip ->
            Skip;
        Python ->
            case interop_server_script() of
                {error, Reason} ->
                    {skip, Reason};
                Script ->
                    run_stdio_transport(Python, Script)
            end
    end.

run_stdio_transport(Python, Script) ->
    application:set_env(erllama_server, mcp_servers, [
        #{
            id => <<"py">>,
            transport => {stdio, #{command => Python, args => [Script]}}
        }
    ]),
    {ok, _Pid} = erllama_server_mcp:start_link(),
    ok = wait_client_ready(<<"py">>, 50),
    ok = erllama_server_mcp:refresh(),
    {Tools, ServerTools} = erllama_server_mcp:catalog(),
    Names = [maps:get(name, T) || T <- Tools],
    ?assert(lists:member(<<"py__echo">>, Names)),
    Spec = maps:get(<<"py__echo">>, ServerTools),
    Ctx = #{
        model => <<"m">>,
        request_id => <<"r">>,
        session_id => undefined,
        config => maps:without([module, type], Spec)
    },
    {ok, Result} = erllama_server_tool_executor_mcp:execute(
        #{<<"text">> => <<"hello stdio">>}, Ctx
    ),
    ?assertEqual(<<"hello stdio">>, maps:get(<<"content">>, Result)).

%% A server that advertises the `resources' capability gets two
%% synthesized meta-tools; both run through the mcp executor by
%% server_id + kind (the agent aggregates tools only). The in-process
%% server always advertises resources, so the no-capability gate isn't
%% exercised here - it's covered by the `server_has_resources' guard.
resources_bridge(Config) ->
    Url = ?config(url, Config),
    application:set_env(erllama_server, mcp_servers, [
        #{id => <<"r">>, transport => {http, Url}}
    ]),
    {ok, _Pid} = erllama_server_mcp:start_link(),
    ok = wait_client_ready(<<"r">>, 50),
    ok = erllama_server_mcp:refresh(),
    {Tools, ServerTools} = erllama_server_mcp:catalog(),
    Names = [maps:get(name, T) || T <- Tools],
    ?assert(lists:member(<<"r__list_resources">>, Names)),
    ?assert(lists:member(<<"r__read_resource">>, Names)),
    %% list_resources -> the registered greeting resource is present.
    {ok, ListResult} = erllama_server_tool_executor_mcp:execute(
        #{}, ctx(maps:get(<<"r__list_resources">>, ServerTools))
    ),
    Uris = [maps:get(<<"uri">>, R) || R <- maps:get(<<"resources">>, ListResult)],
    ?assert(lists:member(<<"mem://greeting">>, Uris)),
    %% read_resource -> its text comes back.
    {ok, ReadResult} = erllama_server_tool_executor_mcp:execute(
        #{<<"uri">> => <<"mem://greeting">>},
        ctx(maps:get(<<"r__read_resource">>, ServerTools))
    ),
    ?assertEqual(<<"hello, world">>, maps:get(<<"content">>, ReadResult)),
    %% read_resource without a uri is a tool error, not a crash.
    ?assertEqual(
        {error, missing_uri},
        erllama_server_tool_executor_mcp:execute(
            #{}, ctx(maps:get(<<"r__read_resource">>, ServerTools))
        )
    ).

%%====================================================================
%% Helpers
%%====================================================================

%% The loop-shaped Ctx the handlers build for an executor call.
ctx(Spec) ->
    #{
        model => <<"m">>,
        request_id => <<"r">>,
        session_id => undefined,
        config => maps:without([module, type], Spec)
    }.

wait_catalog_tool(_Name, 0) ->
    {error, not_in_catalog};
wait_catalog_tool(Name, N) ->
    {Tools, _} = erllama_server_mcp:catalog(),
    case lists:member(Name, [maps:get(name, T) || T <- Tools]) of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_catalog_tool(Name, N - 1)
    end.

python_or_skip() ->
    case os:getenv("INTEROP_PYTHON") of
        false ->
            {skip, "INTEROP_PYTHON not set; stdio transport unverified"};
        Python ->
            case filelib:is_regular(Python) of
                true -> Python;
                false -> {skip, "INTEROP_PYTHON does not point at a file"}
            end
    end.

interop_server_script() ->
    case code:lib_dir(barrel_mcp) of
        {error, _} ->
            {error, "barrel_mcp lib dir not found"};
        Dir ->
            Script = filename:join([Dir, "test", "interop", "server.py"]),
            case filelib:is_regular(Script) of
                true -> Script;
                false -> {error, "barrel_mcp interop server.py not found"}
            end
    end.

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
