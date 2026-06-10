%%% Server-side `web_search` built-in tool executor.
%%%
%%% Implements the `barrel_inference_server_tool_executor' behaviour so the
%%% agentic continue-loop can run a web search in-process when the
%%% model calls `web_search'. Registered (disabled by default) via the
%%% `builtin_tool_executors' app env, e.g.:
%%%
%%%   {builtin_tool_executors, #{
%%%     <<"web_search">> => #{
%%%       module => barrel_inference_server_tool_executor_web_search,
%%%       type => <<"web_search">>,
%%%       provider => tavily,            %% tavily|ollama|brave|mojeek
%%%       api_key => <<"tvly-...">>}     %% |marginalia|searxng (endpoint=)
%%%   }}
%%%
%%% The backend is pluggable via the `provider' config key (carried in
%%% `Ctx.config'). Six providers ship; adding one is a `build_request/3'
%%% clause plus a `parse/2' clause. Every provider normalises to a
%%% compact, model-friendly `#{answer => _, results => [#{title, url,
%%% content}]}`.
-module(barrel_inference_server_tool_executor_web_search).
-behaviour(barrel_inference_server_tool_executor).

-include("barrel_inference_server.hrl").

-export([declare/0, execute/2, build_request/3, parse/2]).

-define(TAVILY_URL, <<"https://api.tavily.com/search">>).
-define(OLLAMA_URL, <<"https://ollama.com/api/web_search">>).
-define(BRAVE_URL, <<"https://api.search.brave.com/res/v1/web/search">>).
-define(MOJEEK_URL, <<"https://api.mojeek.com/search">>).
-define(MARGINALIA_URL, <<"https://api2.marginalia-search.com/search">>).
-define(DEFAULT_MAX_RESULTS, 5).
-define(DEFAULT_TIMEOUT_MS, 10000).
-define(DEFAULT_MAX_BODY, 5 * 1024 * 1024).

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
    %% Brave: query param `q`, key in the x-subscription-token header.
    with_key(Config, fun(Key) ->
        keyed_get(?BRAVE_URL, <<"q">>, Query, <<"x-subscription-token">>, Key, Config)
    end);
build_request(marginalia, Query, Config) ->
    %% Marginalia (Sweden, independent open index): query param `query`,
    %% key in the API-Key header; the free public key is "public".
    with_key(Config, fun(Key) ->
        keyed_get(?MARGINALIA_URL, <<"query">>, Query, <<"api-key">>, Key, Config)
    end);
build_request(mojeek, Query, Config) ->
    %% Mojeek (UK/European, own index): api_key is a query param.
    with_key(Config, fun(Key) ->
        get_with_query(endpoint(Config, ?MOJEEK_URL), [
            {<<"q">>, Query}, {<<"fmt">>, <<"json">>}, {<<"api_key">>, Key}
        ])
    end);
build_request(searxng, Query, Config) ->
    searxng_request(Query, Config);
build_request(Provider, _Query, _Config) ->
    {error, {unsupported_provider, Provider}}.

%% GET with a `count` param and the key carried in AuthHeader (Brave,
%% Marginalia). DefaultUrl may be overridden by the `endpoint' config.
keyed_get(DefaultUrl, QueryKey, Query, AuthHeader, Key, Config) ->
    get_with_query(
        endpoint(Config, DefaultUrl),
        [{QueryKey, Query}, {<<"count">>, count_param(Config)}],
        [{AuthHeader, Key}]
    ).

searxng_request(Query, Config) ->
    case endpoint(Config, undefined) of
        undefined ->
            {error, missing_endpoint};
        Base ->
            get_with_query(<<Base/binary, "/search">>, [
                {<<"q">>, Query}, {<<"format">>, <<"json">>}
            ])
    end.

get_with_query(BaseUrl, Pairs) ->
    get_with_query(BaseUrl, Pairs, []).

%% A GET request with an `accept: application/json' header (plus any
%% ExtraHeaders) and a url-encoded query string appended to BaseUrl.
get_with_query(BaseUrl, Pairs, ExtraHeaders) ->
    Url = <<BaseUrl/binary, "?", (query_string(Pairs))/binary>>,
    Headers = [{<<"accept">>, <<"application/json">>} | ExtraHeaders],
    {ok, {get, Url, Headers, <<>>}}.

count_param(Config) ->
    integer_to_binary(max_results(Config)).

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
    MaxBody = maps:get(max_body, Config, ?DEFAULT_MAX_BODY),
    Client = livery_client:new(#{
        adapter_opts => #{
            hackney => [
                {connect_timeout, Timeout},
                {max_body, MaxBody},
                {ssl_options, tls_opts()}
            ]
        }
    }),
    ReqOpts = #{headers => Headers, body => {full, Body}, timeout => Timeout},
    case livery_client:request(Client, Method, Url, ReqOpts) of
        {ok, Resp} ->
            case {livery_client:status(Resp), livery_client:body(Resp)} of
                {200, {full, RespBody}} -> {ok, RespBody};
                {Status, _} -> {error, {http_status, Status}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Verify provider TLS certs against the OS trust store (avoids MITM).
tls_opts() ->
    [
        {verify, verify_peer},
        {depth, 10},
        {cacerts, public_key:cacerts_get()},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

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
normalise(mojeek, Decoded) ->
    %% Mojeek wraps in `response` and uses `desc`.
    Resp = maps:get(<<"response">>, Decoded, #{}),
    Results = result_list(Resp),
    #{<<"results">> => [result(R, <<"desc">>) || R <- Results, is_map(R)]};
normalise(marginalia, Decoded) ->
    %% Marginalia: top-level `results`, uses `description`.
    Results = result_list(Decoded),
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
