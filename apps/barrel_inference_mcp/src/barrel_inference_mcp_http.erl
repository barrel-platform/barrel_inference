%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% @doc HTTP client to the barrel inference daemon.
%%
%% Resolves the daemon base URL from the `BARREL_URL' environment
%% variable (default `http://localhost:8080') and wraps hackney 4.0
%% with JSON encode/decode. Returns the status code and response
%% headers alongside the decoded body so callers can read response
%% headers (e.g. a future `x-barrel-cache').
%% @end
-module(barrel_inference_mcp_http).

-export([base_url/0, get_json/1, get_text/1, post_json/2, post_json/3]).

-define(DEFAULT_BASE, "http://localhost:8080").

%% @doc Daemon base URL, no trailing slash.
-spec base_url() -> string().
base_url() ->
    case os:getenv("BARREL_URL") of
        false -> ?DEFAULT_BASE;
        "" -> ?DEFAULT_BASE;
        S -> string:trim(S, trailing, "/")
    end.

%% @doc GET a JSON endpoint. Decoded body on 2xx, `{error, {http, Code, Body}}'
%% otherwise.
-spec get_json(Path :: string()) ->
    {ok, Code :: pos_integer(), Headers :: list(), term()} | {error, term()}.
get_json(Path) ->
    request(get, Path, [], <<>>, json).

%% @doc GET a text/plain endpoint (e.g. /metrics). Body returned as a binary.
-spec get_text(Path :: string()) ->
    {ok, Code :: pos_integer(), Headers :: list(), binary()} | {error, term()}.
get_text(Path) ->
    request(get, Path, [], <<>>, text).

%% @doc POST a map as JSON.
-spec post_json(Path :: string(), Map :: map()) ->
    {ok, Code :: pos_integer(), Headers :: list(), term()} | {error, term()}.
post_json(Path, Map) ->
    post_json(Path, Map, []).

%% @doc POST a map as JSON with extra request headers (e.g. x-conversation-id).
-spec post_json(Path :: string(), Map :: map(), Headers :: list()) ->
    {ok, Code :: pos_integer(), Headers :: list(), term()} | {error, term()}.
post_json(Path, Map, ExtraHeaders) ->
    Body = json:encode(Map),
    Headers = [{<<"content-type">>, <<"application/json">>} | ExtraHeaders],
    request(post, Path, Headers, Body, json).

%% Internal -----------------------------------------------------------------

request(Method, Path, Headers, Body, Decode) ->
    URL = list_to_binary(base_url() ++ Path),
    case hackney:request(Method, URL, Headers, Body, []) of
        {ok, Code, RespHeaders, RawBody} ->
            {ok, Code, RespHeaders, decode(Decode, RawBody)};
        {error, _} = E ->
            E
    end.

decode(text, RawBody) ->
    RawBody;
decode(json, <<>>) ->
    #{};
decode(json, RawBody) ->
    try
        json:decode(RawBody)
    catch
        _:_ -> RawBody
    end.
