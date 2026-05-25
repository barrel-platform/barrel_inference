%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cluster_cli).
-moduledoc """
`barrel-inference cluster <subcmd>` entry point.

The top-level CLI (`barrel_inference_cli`) delegates the reserved `cluster`
namespace here via `code:ensure_loaded/1`. Like the rest of the CLI this is a thin
HTTP client (hackney only): it queries the running daemon's cluster endpoints
rather than joining the overlay itself.

The `/cluster/*` endpoints are served by the clustered server (Phase 2). When they
are absent the command says so rather than failing opaquely.
""".

-export([run/1]).

-define(DEFAULT_HOST, "http://127.0.0.1:8080").

-spec run([string()]) -> ok | no_return().
run(["status" | _]) ->
    get_print("/cluster/status");
run(["nodes" | _]) ->
    get_print("/cluster/nodes");
run(["peers" | _]) ->
    get_print("/cluster/nodes");
run(["help" | _]) ->
    usage();
run([]) ->
    usage();
run(_Other) ->
    usage(),
    halt(2).

%% =============================================================================
%% internal
%% =============================================================================

usage() ->
    io:put_chars(
        "barrel-inference cluster <subcommand>\n"
        "\n"
        "  status    show this node's view of the cluster (peers, models, load)\n"
        "  nodes     list cluster member nodes\n"
        "  help      this message\n"
        "\n"
        "Talks to the daemon at BARREL_INFERENCE_HOST (default "
        ?DEFAULT_HOST
        ").\n"
    ).

get_print(Path) ->
    {ok, _} = application:ensure_all_started(hackney),
    Url = list_to_binary(base_url() ++ Path),
    case hackney:request(get, Url, [], <<>>, [{recv_timeout, 10000}]) of
        {ok, 200, _Hdrs, Body} ->
            io:put_chars([Body, "\n"]);
        {ok, 404, _Hdrs, _Body} ->
            io:put_chars(
                "cluster endpoint not available on this daemon.\n"
                "It is served by a clustered build of barrel_inference_server.\n"
            ),
            halt(3);
        {ok, Status, _Hdrs, Body} ->
            io:format("error (HTTP ~p): ~s~n", [Status, Body]),
            halt(1);
        {error, Reason} ->
            io:format("cannot reach ~s: ~p~n", [Url, Reason]),
            halt(1)
    end.

base_url() ->
    case os:getenv("BARREL_INFERENCE_HOST") of
        false -> ?DEFAULT_HOST;
        "" -> ?DEFAULT_HOST;
        Host -> Host
    end.
