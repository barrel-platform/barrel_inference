%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_search).
-moduledoc """
Search models on remote registries.

Returns a unified hit list across the configured sources. The default
sources are HuggingFace Hub (`hf`) and the Ollama registry catalog
(`ollama`). Each hit carries:

- `source` `hf | ollama`
- `id` a fetch spec acceptable to `barrel_inference_server_fetch:fetch/1`
- `name` human-readable repo name
- `description` short blurb (HF) or `<<>>` (Ollama: not exposed)
- `downloads`, `last_modified`, `tags` metadata when available
- `files` list of `#{id, path | tag}` for each candidate inside
  the repo

Sources are queried sequentially. The `limit` option caps each
source's results, then the merged list is truncated to
`limit * length(sources)`.
""".

-export([search/1, search/2]).

-export_type([hit/0, opts/0]).

-type hit() :: #{
    source := hf | ollama,
    id := binary(),
    name := binary(),
    description := binary(),
    downloads := non_neg_integer(),
    last_modified := binary(),
    tags := [binary()],
    files := [map()]
}.

-type opts() :: #{
    limit => pos_integer(),
    sources => [hf | ollama],
    hf_filter => gguf | safetensors | any,
    timeout_ms => pos_integer()
}.

-spec search(binary() | string()) -> {ok, [hit()]} | {error, term()}.
search(Query) ->
    search(Query, #{}).

-spec search(binary() | string(), opts()) -> {ok, [hit()]} | {error, term()}.
search(Query, Opts) when is_map(Opts) ->
    Sources = maps:get(sources, Opts, [hf, ollama]),
    Timeout = maps:get(timeout_ms, Opts, 10000),
    Fetch = fun(URL, Hdrs) -> http_get_body(URL, Hdrs, Timeout) end,
    Results = [
        {Src, run(Src, Query, Opts, Fetch)}
     || Src <- Sources
    ],
    Hits = lists:flatten([H || {_, {ok, H}} <- Results]),
    {ok, Hits}.

run(hf, Query, Opts, Fetch) ->
    barrel_inference_server_search_hf:search(Query, Opts, Fetch);
run(ollama, Query, Opts, Fetch) ->
    barrel_inference_server_search_ollama:search(Query, Opts, Fetch);
run(Other, _, _, _) ->
    {error, {unknown_source, Other}}.

http_get_body(URL, Hdrs, Timeout) ->
    Client = livery_client:new(#{
        adapter_opts => #{
            hackney => [
                {follow_redirect, true},
                {max_redirect, 5},
                {connect_timeout, Timeout}
            ]
        }
    }),
    case livery_client:request(Client, get, URL, #{headers => Hdrs, timeout => Timeout}) of
        {ok, Resp} ->
            {full, Body} = livery_client:body(Resp),
            {ok, livery_client:status(Resp), livery_client:headers(Resp), Body};
        {error, _} = E ->
            E
    end.
