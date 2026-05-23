%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Deterministic, dependency-free executor used by the tool-executor
%% and continue-loop tests. Declares a `web_search`-shaped tool and
%% echoes its arguments back, so the registry + loop can be exercised
%% without shipping a production executor or hitting the network.
-module(erllama_server_tool_executor_stub).
-behaviour(erllama_server_tool_executor).

-export([declare/0, execute/2]).

declare() ->
    #{
        name => <<"web_search">>,
        description => <<"Stub web search (echoes its arguments).">>,
        schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"query">> => #{<<"type">> => <<"string">>}
            },
            <<"required">> => [<<"query">>]
        }
    }.

execute(Args, _Ctx) ->
    {ok, #{<<"echo">> => Args}}.
