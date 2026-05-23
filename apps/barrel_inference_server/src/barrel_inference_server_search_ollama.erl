%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_search_ollama).
-moduledoc """
Ollama registry search backend.

Ollama publishes its public models through the OCI registry at
`registry.ollama.ai`. There is no documented JSON search endpoint;
the registry catalog (`/v2/_catalog`) is the closest stable public
API. We fetch it once per call, substring-match the query against
the repository names client-side, and return the matches as unified
hits.

Caveat: the catalog response carries no descriptions, download
counts, or modification timestamps. Those fields are emitted with
empty defaults so the unified hit shape stays consistent across
sources.
""".

-export([search/3]).

-define(CATALOG_URL, <<"https://registry.ollama.ai/v2/_catalog?n=10000">>).

-spec search(binary() | string(), map(), fun((binary(), [{binary(), binary()}]) -> term())) ->
    {ok, [map()]} | {error, term()}.
search(Query, Opts, Fetch) when is_function(Fetch, 2) ->
    case Fetch(?CATALOG_URL, headers()) of
        {ok, 200, _, Body} when is_binary(Body) -> filter(Body, to_bin(Query), Opts);
        {ok, Status, _, _} -> {error, {ollama_catalog_status, Status}};
        {error, _} = E -> E
    end.

filter(Body, Query, Opts) ->
    try json:decode(Body) of
        #{<<"repositories">> := Repos} when is_list(Repos) -> {ok, build_hits(Query, Repos, Opts)};
        _ -> {error, ollama_bad_catalog}
    catch
        _:Reason -> {error, {ollama_catalog_parse, Reason}}
    end.

build_hits(Query, Repos, Opts) ->
    Limit = maps:get(limit, Opts, 20),
    Lower = string:lowercase(Query),
    Matches = [R || R <- Repos, is_binary(R), matches(string:lowercase(R), Lower)],
    [hit_from(R) || R <- lists:sublist(Matches, Limit)].

matches(_, <<>>) ->
    true;
matches(Repo, Query) ->
    binary:match(Repo, Query) =/= nomatch.

hit_from(Repo) ->
    {Library, Name} = split_repo(Repo),
    #{
        source => ollama,
        id => iolist_to_binary([<<"ollama://">>, Library, <<"/">>, Name]),
        name => Repo,
        description => <<>>,
        downloads => 0,
        last_modified => <<>>,
        tags => [<<"latest">>],
        files => [
            #{
                id => iolist_to_binary([<<"ollama://">>, Library, <<"/">>, Name, <<":latest">>]),
                tag => <<"latest">>
            }
        ]
    }.

split_repo(Repo) ->
    case binary:split(Repo, <<"/">>) of
        [Library, Name] -> {Library, Name};
        [Single] -> {<<"library">>, Single}
    end.

headers() ->
    [
        {<<"User-Agent">>,
            <<"barrel_inference_server/0.1.0 (+https://github.com/barrel-platform/barrel_inference)">>},
        {<<"Accept">>, <<"application/json">>}
    ].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
