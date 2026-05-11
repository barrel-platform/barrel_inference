%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_search_hf).
-moduledoc """
HuggingFace Hub search backend.

Queries `https://huggingface.co/api/models` and returns a list of
unified search hits. The fetcher is injected so unit tests can run
offline.
""".

-export([search/3]).

-spec search(binary() | string(), map(), fun((binary(), [{binary(), binary()}]) -> term())) ->
    {ok, [map()]} | {error, term()}.
search(Query, Opts, Fetch) when is_function(Fetch, 2) ->
    URL = build_url(Query, Opts),
    case Fetch(URL, headers()) of
        {ok, 200, _, Body} when is_binary(Body) -> parse_results(Body);
        {ok, Status, _, _} -> {error, {hf_search_status, Status}};
        {error, _} = E -> E
    end.

build_url(Query, Opts) ->
    Q = to_bin(Query),
    Limit = integer_to_binary(maps:get(limit, Opts, 20)),
    Filter = filter_param(maps:get(hf_filter, Opts, gguf)),
    iolist_to_binary([
        <<"https://huggingface.co/api/models?search=">>,
        uri_string:quote(Q),
        Filter,
        <<"&limit=">>,
        Limit,
        <<"&full=true">>,
        <<"&sort=downloads">>,
        <<"&direction=-1">>
    ]).

filter_param(any) -> <<>>;
filter_param(gguf) -> <<"&filter=gguf">>;
filter_param(safetensors) -> <<"&filter=safetensors">>.

headers() ->
    [
        {<<"User-Agent">>, <<"erllama_server/0.1.0 (+https://github.com/erllama/erllama_server)">>},
        {<<"Accept">>, <<"application/json">>}
        | hf_auth_headers()
    ].

hf_auth_headers() ->
    case os:getenv("HF_TOKEN") of
        false -> [];
        "" -> [];
        Token -> [{<<"Authorization">>, iolist_to_binary([<<"Bearer ">>, Token])}]
    end.

parse_results(Body) ->
    try json:decode(Body) of
        Items when is_list(Items) -> {ok, [hit_from(I) || I <- Items, is_map(I)]};
        _ -> {error, hf_bad_search_response}
    catch
        _:Reason -> {error, {hf_search_parse, Reason}}
    end.

hit_from(Item) ->
    Id = maps:get(<<"id">>, Item, <<>>),
    #{
        source => hf,
        id => canonical_id(Id),
        name => Id,
        description => maps:get(<<"description">>, Item, <<>>),
        downloads => maps:get(<<"downloads">>, Item, 0),
        last_modified => maps:get(<<"lastModified">>, Item, <<>>),
        tags => filter_binaries(maps:get(<<"tags">>, Item, [])),
        files => extract_gguf_files(Item)
    }.

%% A user that wants the top file from this hit can pass the canonical
%% id straight to `erllama_server_fetch:fetch/1`. The auto-pick logic
%% there picks a sensible GGUF for them.
canonical_id(Id) ->
    iolist_to_binary([<<"hf://">>, Id]).

extract_gguf_files(Item) ->
    Siblings = maps:get(<<"siblings">>, Item, []),
    [
        #{
            id => iolist_to_binary([<<"hf://">>, maps:get(<<"id">>, Item, <<>>), <<"/">>, F]),
            path => F
        }
     || #{<<"rfilename">> := F} <- Siblings,
        is_binary(F),
        ends_with(F, <<".gguf">>)
    ].

filter_binaries(Items) ->
    [I || I <- Items, is_binary(I)].

ends_with(Bin, Suffix) ->
    BS = byte_size(Bin),
    SS = byte_size(Suffix),
    BS >= SS andalso binary:part(Bin, BS - SS, SS) =:= Suffix.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
