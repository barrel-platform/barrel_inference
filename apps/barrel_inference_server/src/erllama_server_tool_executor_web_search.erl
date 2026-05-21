%%% Server-side `web_search` built-in tool executor.
%%%
%%% Implements the `erllama_server_tool_executor' behaviour so the
%%% agentic continue-loop can run a web search in-process when the
%%% model calls `web_search'. Registered (disabled by default) via the
%%% `builtin_tool_executors' app env, e.g.:
%%%
%%%   {builtin_tool_executors, #{
%%%     <<"web_search">> => #{
%%%       module => erllama_server_tool_executor_web_search,
%%%       type => <<"web_search">>,
%%%       provider => tavily,            %% tavily | ollama | brave | searxng
%%%       api_key => <<"tvly-...">>}     %% endpoint => ... for searxng
%%%   }}
%%%
%%% The backend is pluggable via the `provider' config key (carried in
%%% `Ctx.config'). Four providers ship; adding one is a `build_request/3'
%%% clause plus a `parse/2' clause. Every provider normalises to a
%%% compact, model-friendly `#{answer => _, results => [#{title, url,
%%% content}]}`.
-module(erllama_server_tool_executor_web_search).
-behaviour(erllama_server_tool_executor).

-include("erllama_server.hrl").

-export([declare/0, execute/2, build_request/3, parse/2]).

-define(TAVILY_URL, <<"https://api.tavily.com/search">>).
-define(OLLAMA_URL, <<"https://ollama.com/api/web_search">>).
-define(BRAVE_URL, <<"https://api.search.brave.com/res/v1/web/search">>).
-define(DEFAULT_MAX_RESULTS, 5).
-define(DEFAULT_TIMEOUT_MS, 10000).

declare() ->
    #{
        name => <<"web_search">>,
        description =>
            <<"Search the web and return relevant results (title, url, snippet).">>,
        schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"query">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The search query.">>
                }
            },
            <<"required">> => [<<"query">>]
        }
    }.

execute(#{<<"query">> := Query}, Ctx) when is_binary(Query), Query =/= <<>> ->
    Config = maps:get(config, Ctx, #{}),
    Provider = maps:get(provider, Config, tavily),
    case build_request(Provider, Query, Config) of
        {ok, {Method, Url, Headers, Body}} ->
            case http_call(Method, Url, Headers, Body, Config) of
                {ok, RespBody} -> {ok, parse(Provider, RespBody)};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
execute(_Args, _Ctx) ->
    {error, missing_query}.

%%====================================================================
%% Request building (pure)
%%====================================================================

%% Returns `{ok, {Method, Url, Headers, Body}}' or `{error, Reason}'.
-spec build_request(atom(), binary(), map()) ->
    {ok, {get | post, binary(), [{binary(), binary()}], binary()}} | {error, term()}.
build_request(tavily, Query, Config) ->
    with_key(Config, fun(Key) ->
        {ok, {post, endpoint(Config, ?TAVILY_URL), bearer_headers(Key), search_body(Query, Config)}}
    end);
build_request(ollama, Query, Config) ->
    with_key(Config, fun(Key) ->
        {ok, {post, endpoint(Config, ?OLLAMA_URL), bearer_headers(Key), search_body(Query, Config)}}
    end);
build_request(brave, Query, Config) ->
    with_key(Config, fun(Key) -> brave_request(Query, Config, Key) end);
build_request(searxng, Query, Config) ->
    searxng_request(Query, Config);
build_request(Provider, _Query, _Config) ->
    {error, {unsupported_provider, Provider}}.

brave_request(Query, Config, Key) ->
    Qs = query_string([
        {<<"q">>, Query},
        {<<"count">>, integer_to_binary(max_results(Config))}
    ]),
    Url = <<(endpoint(Config, ?BRAVE_URL))/binary, "?", Qs/binary>>,
    Headers = [
        {<<"accept">>, <<"application/json">>},
        {<<"x-subscription-token">>, Key}
    ],
    {ok, {get, Url, Headers, <<>>}}.

searxng_request(Query, Config) ->
    case endpoint(Config, undefined) of
        undefined ->
            {error, missing_endpoint};
        Base ->
            Qs = query_string([{<<"q">>, Query}, {<<"format">>, <<"json">>}]),
            Url = <<Base/binary, "/search?", Qs/binary>>,
            {ok, {get, Url, [{<<"accept">>, <<"application/json">>}], <<>>}}
    end.

with_key(Config, Fun) ->
    case maps:get(api_key, Config, undefined) of
        Key when is_binary(Key), Key =/= <<>> -> Fun(Key);
        _ -> {error, missing_api_key}
    end.

bearer_headers(Key) ->
    [
        {<<"content-type">>, <<"application/json">>},
        {<<"authorization">>, <<"Bearer ", Key/binary>>}
    ].

endpoint(Config, Default) ->
    maps:get(endpoint, Config, Default).

max_results(Config) ->
    maps:get(max_results, Config, ?DEFAULT_MAX_RESULTS).

search_body(Query, Config) ->
    iolist_to_binary(
        json:encode(#{<<"query">> => Query, <<"max_results">> => max_results(Config)})
    ).

query_string(Pairs) ->
    iolist_to_binary(uri_string:compose_query(Pairs)).

%%====================================================================
%% HTTP
%%====================================================================

http_call(Method, Url, Headers, Body, Config) ->
    Timeout = maps:get(timeout_ms, Config, ?DEFAULT_TIMEOUT_MS),
    Opts = [with_body, {recv_timeout, Timeout}, {connect_timeout, Timeout}],
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, 200, _RespHeaders, RespBody} ->
            {ok, RespBody};
        {ok, Status, _RespHeaders, _RespBody} ->
            {error, {http_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Response parsing (pure)
%%====================================================================

%% Normalise a provider response to `#{answer => _, results =>
%% [#{title, url, content}]}'. Tolerant of a malformed body (returns
%% empty results rather than crashing).
-spec parse(atom(), binary()) -> map().
parse(Provider, RespBody) ->
    try json:decode(RespBody) of
        Decoded when is_map(Decoded) ->
            normalise(Provider, Decoded);
        _ ->
            #{<<"results">> => []}
    catch
        _:_ -> #{<<"results">> => []}
    end.

normalise(brave, Decoded) ->
    Web = maps:get(<<"web">>, Decoded, #{}),
    Results = result_list(Web),
    #{<<"results">> => [result(R, <<"description">>) || R <- Results, is_map(R)]};
normalise(tavily, Decoded) ->
    Results = result_list(Decoded),
    #{
        <<"answer">> => maps:get(<<"answer">>, Decoded, null),
        <<"results">> => [result(R, <<"content">>) || R <- Results, is_map(R)]
    };
normalise(_Provider, Decoded) ->
    %% ollama, searxng: `{results: [{title, url, content}]}'.
    Results = result_list(Decoded),
    #{<<"results">> => [result(R, <<"content">>) || R <- Results, is_map(R)]}.

result_list(Map) ->
    case maps:get(<<"results">>, Map, []) of
        L when is_list(L) -> L;
        _ -> []
    end.

result(R, ContentKey) ->
    #{
        <<"title">> => maps:get(<<"title">>, R, <<>>),
        <<"url">> => maps:get(<<"url">>, R, <<>>),
        <<"content">> => maps:get(ContentKey, R, <<>>)
    }.
