%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_tool_executor_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(KEY, {barrel_inference_server_config, builtin_tool_executors}).

all() ->
    [
        lookup_type_hit,
        lookup_type_miss,
        default_registry_empty,
        declare_dispatch,
        execute_dispatch,
        app_env_merges_over_default
    ].

init_per_testcase(_, Config) ->
    persistent_term:put(?KEY, #{
        <<"web_search">> => #{
            module => barrel_inference_server_tool_executor_stub,
            type => <<"web_search">>
        }
    }),
    Config.

end_per_testcase(_, _Config) ->
    persistent_term:erase(?KEY),
    ok.

lookup_type_hit(_Config) ->
    ?assertMatch(
        {ok, #{module := barrel_inference_server_tool_executor_stub, type := <<"web_search">>}},
        barrel_inference_server_tool_executor:lookup_type(<<"web_search">>)
    ).

lookup_type_miss(_Config) ->
    ?assertEqual(
        not_found, barrel_inference_server_tool_executor:lookup_type(<<"image_generation">>)
    ).

default_registry_empty(_Config) ->
    %% With no registry configured the accessor falls back to the
    %% empty default, so every built-in type misses.
    persistent_term:erase(?KEY),
    ?assertEqual(#{}, barrel_inference_server_config:builtin_tool_executors()),
    ?assertEqual(not_found, barrel_inference_server_tool_executor:lookup_type(<<"web_search">>)).

declare_dispatch(_Config) ->
    {ok, Spec} = barrel_inference_server_tool_executor:lookup_type(<<"web_search">>),
    Tool = barrel_inference_server_tool_executor:declare(Spec),
    ?assertEqual(<<"web_search">>, maps:get(name, Tool)),
    ?assert(is_map(maps:get(schema, Tool))).

execute_dispatch(_Config) ->
    {ok, Spec} = barrel_inference_server_tool_executor:lookup_type(<<"web_search">>),
    ?assertEqual(
        {ok, #{<<"echo">> => #{<<"query">> => <<"hi">>}}},
        barrel_inference_server_tool_executor:execute(Spec, #{<<"query">> => <<"hi">>}, #{})
    ).

app_env_merges_over_default(_Config) ->
    %% A registered entry is resolvable; an unregistered type still
    %% misses. (The init merge keeps defaults + app env; here the
    %% default is empty so the registered entry is the whole map.)
    ?assertMatch({ok, _}, barrel_inference_server_tool_executor:lookup_type(<<"web_search">>)),
    ?assertEqual(not_found, barrel_inference_server_tool_executor:lookup_type(<<"unknown">>)).
