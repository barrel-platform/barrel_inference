%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Cross-app integration smoke for the umbrella: boot the full
%% barrel_inference_server supervision tree (which starts the
%% barrel_inference runtime + NIF) and hit its liveness endpoint with
%% the same HTTP client the CLI uses (hackney). No model is loaded;
%% /health is liveness-only and answers 200 as soon as the BEAM is up.
-module(barrel_inference_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([health_endpoint_responds/1]).

all() ->
    [health_endpoint_responds].

init_per_suite(Config) ->
    Port = free_port(),
    application:set_env(barrel_inference_server, port, Port),
    application:set_env(barrel_inference_server, model_aliases, #{}),
    {ok, Started} = application:ensure_all_started(barrel_inference_server),
    {ok, _} = application:ensure_all_started(hackney),
    ok = wait_listening(Port, 100),
    [{started, Started}, {port, Port} | Config].

end_per_suite(Config) ->
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    ok.

health_endpoint_responds(Config) ->
    Port = ?config(port, Config),
    URL = iolist_to_binary([
        "http://127.0.0.1:", integer_to_list(Port), "/health"
    ]),
    %% hackney 4.0 returns the body inline as the 4th element.
    {ok, Code, _Hdrs, _Body} = hackney:request(get, URL, [], <<>>, []),
    ?assertEqual(200, Code).

%% ----------------------------------------------------------------------------

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(S),
    ok = gen_tcp:close(S),
    P.

wait_listening(_Port, 0) ->
    {error, timeout};
wait_listening(Port, N) ->
    case gen_tcp:connect("127.0.0.1", Port, [], 200) of
        {ok, S} ->
            ok = gen_tcp:close(S),
            ok;
        {error, _} ->
            timer:sleep(100),
            wait_listening(Port, N - 1)
    end.
