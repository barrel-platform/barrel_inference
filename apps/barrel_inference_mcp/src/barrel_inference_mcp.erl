%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% @doc Public launcher for the Barrel Inference MCP server.
%%
%% The server exposes the local Barrel Inference runtime as MCP tools
%% (run inference, list/tune models, read metrics). It is a thin client
%% of the barrel HTTP daemon; point it at the daemon with the
%% `BARREL_URL' environment variable (default `http://localhost:8080').
%%
%% Two transports:
%% <ul>
%%   <li>{@link run_stdio/0} — blocking stdio loop for Claude Code/Desktop.
%%       This is what the plugin launcher invokes.</li>
%%   <li>{@link start_http/1} — Streamable HTTP transport for remote clients.</li>
%% </ul>
%% @end
-module(barrel_inference_mcp).

-export([run_stdio/0, start_http/1]).

%% @doc Boot the application and run the MCP stdio server (blocking).
%% Intended as the entry point for `erl -eval "barrel_inference_mcp:run_stdio()"'.
-spec run_stdio() -> ok | no_return().
run_stdio() ->
    {ok, _} = application:ensure_all_started(barrel_inference_mcp),
    barrel_mcp:start_stdio().

%% @doc Boot the application and expose the tools over Streamable HTTP.
-spec start_http(Opts :: map()) -> {ok, pid()} | {error, term()}.
start_http(Opts) ->
    {ok, _} = application:ensure_all_started(barrel_inference_mcp),
    barrel_mcp:start_http_stream(Opts).
