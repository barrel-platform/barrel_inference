%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_tool_executor_web_search_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, erllama_server_tool_executor_web_search).

%%====================================================================
%% declare / execute guards
%%====================================================================

declare_shape_test() ->
    Tool = ?M:declare(),
    ?assertEqual(<<"web_search">>, maps:get(name, Tool)),
    Schema = maps:get(schema, Tool),
    ?assertEqual([<<"query">>], maps:get(<<"required">>, Schema)),
    ?assert(is_map(maps:get(<<"properties">>, Schema))).

missing_query_test() ->
    ?assertEqual({error, missing_query}, ?M:execute(#{}, #{})),
    ?assertEqual({error, missing_query}, ?M:execute(#{<<"query">> => <<>>}, #{})).

%%====================================================================
%% build_request per provider
%%====================================================================

build_tavily_test() ->
    {ok, {Method, Url, Headers, Body}} =
        ?M:build_request(tavily, <<"capital of france">>, #{api_key => <<"tvly-k">>}),
    ?assertEqual(post, Method),
    ?assertEqual(<<"https://api.tavily.com/search">>, Url),
    ?assertEqual(<<"Bearer tvly-k">>, header(<<"authorization">>, Headers)),
    Decoded = json:decode(Body),
    ?assertEqual(<<"capital of france">>, maps:get(<<"query">>, Decoded)).

build_ollama_test() ->
    {ok, {post, Url, Headers, Body}} =
        ?M:build_request(ollama, <<"q">>, #{api_key => <<"ok">>}),
    ?assertEqual(<<"https://ollama.com/api/web_search">>, Url),
    ?assertEqual(<<"Bearer ok">>, header(<<"authorization">>, Headers)),
    ?assertEqual(<<"q">>, maps:get(<<"query">>, json:decode(Body))).

build_brave_test() ->
    {ok, {Method, Url, Headers, Body}} =
        ?M:build_request(brave, <<"hello world">>, #{api_key => <<"BSA-k">>}),
    ?assertEqual(get, Method),
    ?assertEqual(<<>>, Body),
    ?assertEqual(<<"BSA-k">>, header(<<"x-subscription-token">>, Headers)),
    ?assert(binary:match(Url, <<"api.search.brave.com/res/v1/web/search?">>) =/= nomatch),
    %% the query is url-encoded into the q param
    ?assert(binary:match(Url, <<"q=hello">>) =/= nomatch).

build_mojeek_test() ->
    {ok, {Method, Url, _Headers, Body}} =
        ?M:build_request(mojeek, <<"hello">>, #{api_key => <<"mjk">>}),
    ?assertEqual(get, Method),
    ?assertEqual(<<>>, Body),
    ?assert(binary:match(Url, <<"api.mojeek.com/search?">>) =/= nomatch),
    %% Mojeek carries the key + json format as query params.
    ?assert(binary:match(Url, <<"fmt=json">>) =/= nomatch),
    ?assert(binary:match(Url, <<"api_key=mjk">>) =/= nomatch).

build_marginalia_test() ->
    {ok, {get, Url, Headers, <<>>}} =
        ?M:build_request(marginalia, <<"hello">>, #{api_key => <<"public">>}),
    ?assert(binary:match(Url, <<"api2.marginalia-search.com/search?">>) =/= nomatch),
    ?assert(binary:match(Url, <<"query=hello">>) =/= nomatch),
    %% the key travels in the API-Key header, not the URL
    ?assertEqual(<<"public">>, header(<<"api-key">>, Headers)),
    ?assertEqual(nomatch, binary:match(Url, <<"public">>)).

build_searxng_test() ->
    {ok, {get, Url, _Headers, <<>>}} =
        ?M:build_request(searxng, <<"q">>, #{endpoint => <<"http://127.0.0.1:8888">>}),
    ?assertEqual(<<"http://127.0.0.1:8888/search?q=q&format=json">>, Url).

build_searxng_missing_endpoint_test() ->
    ?assertEqual({error, missing_endpoint}, ?M:build_request(searxng, <<"q">>, #{})).

build_missing_api_key_test() ->
    ?assertEqual({error, missing_api_key}, ?M:build_request(tavily, <<"q">>, #{})),
    ?assertEqual({error, missing_api_key}, ?M:build_request(brave, <<"q">>, #{})).

build_unsupported_provider_test() ->
    ?assertEqual(
        {error, {unsupported_provider, nope}},
        ?M:build_request(nope, <<"q">>, #{})
    ).

%%====================================================================
%% parse per provider
%%====================================================================

parse_tavily_test() ->
    Body = enc(#{
        <<"answer">> => <<"Paris.">>,
        <<"results">> => [
            #{
                <<"title">> => <<"Paris">>,
                <<"url">> => <<"https://e/paris">>,
                <<"content">> => <<"capital of France">>,
                <<"score">> => 0.98
            },
            <<"not-a-map">>
        ]
    }),
    Parsed = ?M:parse(tavily, Body),
    ?assertEqual(<<"Paris.">>, maps:get(<<"answer">>, Parsed)),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"Paris">>, maps:get(<<"title">>, R)),
    ?assertEqual(<<"https://e/paris">>, maps:get(<<"url">>, R)),
    ?assertEqual(<<"capital of France">>, maps:get(<<"content">>, R)),
    ?assertEqual(false, maps:is_key(<<"score">>, R)).

parse_ollama_test() ->
    Body = enc(#{
        <<"results">> => [
            #{
                <<"title">> => <<"Ollama">>,
                <<"url">> => <<"https://ollama.com/">>,
                <<"content">> => <<"snippet">>
            }
        ]
    }),
    Parsed = ?M:parse(ollama, Body),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"Ollama">>, maps:get(<<"title">>, R)),
    ?assertEqual(<<"snippet">>, maps:get(<<"content">>, R)).

parse_brave_test() ->
    %% Brave nests results under `web` and uses `description`.
    Body = enc(#{
        <<"web">> => #{
            <<"results">> => [
                #{
                    <<"title">> => <<"T">>,
                    <<"url">> => <<"https://e">>,
                    <<"description">> => <<"desc">>
                }
            ]
        }
    }),
    Parsed = ?M:parse(brave, Body),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"T">>, maps:get(<<"title">>, R)),
    %% description is mapped onto the unified `content` field
    ?assertEqual(<<"desc">>, maps:get(<<"content">>, R)).

parse_searxng_test() ->
    Body = enc(#{
        <<"results">> => [
            #{
                <<"title">> => <<"S">>,
                <<"url">> => <<"https://e">>,
                <<"content">> => <<"c">>
            }
        ]
    }),
    Parsed = ?M:parse(searxng, Body),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"S">>, maps:get(<<"title">>, R)).

parse_mojeek_test() ->
    %% Mojeek nests results under `response` and uses `desc`.
    Body = enc(#{
        <<"response">> => #{
            <<"results">> => [
                #{
                    <<"title">> => <<"Paris - Wikipedia">>,
                    <<"url">> => <<"https://en.wikipedia.org/wiki/Paris">>,
                    <<"desc">> => <<"Paris is the capital of France.">>
                }
            ]
        }
    }),
    Parsed = ?M:parse(mojeek, Body),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"Paris - Wikipedia">>, maps:get(<<"title">>, R)),
    %% desc is mapped onto the unified `content` field
    ?assertEqual(<<"Paris is the capital of France.">>, maps:get(<<"content">>, R)).

parse_marginalia_test() ->
    %% Marginalia: top-level results, uses `description`.
    Body = enc(#{
        <<"results">> => [
            #{
                <<"title">> => <<"A blog about Paris">>,
                <<"url">> => <<"https://example.org/paris">>,
                <<"description">> => <<"Notes on the capital of France.">>
            }
        ]
    }),
    Parsed = ?M:parse(marginalia, Body),
    [R] = maps:get(<<"results">>, Parsed),
    ?assertEqual(<<"A blog about Paris">>, maps:get(<<"title">>, R)),
    ?assertEqual(<<"Notes on the capital of France.">>, maps:get(<<"content">>, R)).

parse_malformed_test() ->
    ?assertEqual(#{<<"results">> => []}, ?M:parse(tavily, <<"{not json">>)),
    ?assertEqual(#{<<"results">> => []}, ?M:parse(brave, <<"nope">>)).

%%====================================================================
%% Helpers
%%====================================================================

enc(Map) -> iolist_to_binary(json:encode(Map)).

header(Name, Headers) ->
    {Name, V} = lists:keyfind(Name, 1, Headers),
    V.
