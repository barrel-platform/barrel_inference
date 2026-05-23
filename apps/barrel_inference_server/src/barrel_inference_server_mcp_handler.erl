%%% `barrel_mcp_client' handler for the MCP bridge.
%%%
%%% A connected MCP server signals a changed tool/resource set with a
%%% `notifications/<kind>/list_changed' notification. barrel_mcp routes
%%% every server notification to this module's `handle_notification/3'
%%% (it runs inside the client's gen_statem). On a list_changed we kick
%%% an **async** catalog rebuild on the manager via
%%% `barrel_inference_server_mcp:refresh_async/0' - a synchronous refresh would
%%% deadlock, because the rebuild calls back into this same client to
%%% list its tools.
%%%
%%% We service no server-initiated requests (no sampling/roots), so
%%% `handle_request/3' delegates to the library's default
%%% (`method_not_found').
-module(barrel_inference_server_mcp_handler).
-behaviour(barrel_mcp_client_handler).

-export([init/1, handle_request/3, handle_notification/3, terminate/2]).

init(_Args) ->
    {ok, undefined}.

handle_request(Method, Params, State) ->
    barrel_mcp_client_handler_default:handle_request(Method, Params, State).

handle_notification(<<"notifications/tools/list_changed">>, _Params, State) ->
    barrel_inference_server_mcp:refresh_async(),
    {ok, State};
handle_notification(<<"notifications/resources/list_changed">>, _Params, State) ->
    barrel_inference_server_mcp:refresh_async(),
    {ok, State};
handle_notification(<<"notifications/prompts/list_changed">>, _Params, State) ->
    barrel_inference_server_mcp:refresh_async(),
    {ok, State};
handle_notification(_Method, _Params, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
