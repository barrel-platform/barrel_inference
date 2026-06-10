%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% @doc Application entry for the Barrel Inference MCP server.
%%
%% On start the application registers the barrel tool set against
%% `barrel_mcp' and supervises nothing else of its own. A transport
%% (stdio for Claude Code/Desktop, or Streamable HTTP) is started
%% separately by the launcher in {@link barrel_inference_mcp}.
%% @end
-module(barrel_inference_mcp_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = barrel_inference_mcp_tools:register_all(),
    barrel_inference_mcp_sup:start_link().

stop(_State) ->
    ok.
