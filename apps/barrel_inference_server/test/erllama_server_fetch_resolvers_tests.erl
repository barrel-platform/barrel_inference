%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_fetch_resolvers_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_hf_simple_test() ->
    ?assertMatch(
        {ok, {hf, <<"org">>, <<"repo">>, <<"path/to/file.gguf">>, <<"main">>}},
        erllama_server_fetch_resolvers:parse(<<"hf://org/repo/path/to/file.gguf">>)
    ).

parse_hf_revision_test() ->
    ?assertMatch(
        {ok, {hf, <<"org">>, <<"repo">>, <<"f.gguf">>, <<"v1.2">>}},
        erllama_server_fetch_resolvers:parse(<<"hf://org/repo/f.gguf@v1.2">>)
    ).

parse_hf_string_input_test() ->
    ?assertMatch(
        {ok, {hf, _, _, _, _}},
        erllama_server_fetch_resolvers:parse("hf://a/b/c.gguf")
    ).

parse_hf_no_path_returns_undefined_path_test() ->
    ?assertMatch(
        {ok, {hf, <<"org">>, <<"repo">>, undefined, <<"main">>}},
        erllama_server_fetch_resolvers:parse(<<"hf://org/repo">>)
    ).

parse_hf_missing_repo_test() ->
    ?assertMatch(
        {error, {bad_hf_spec, _}},
        erllama_server_fetch_resolvers:parse(<<"hf://org">>)
    ).

parse_ollama_default_tag_test() ->
    ?assertMatch(
        {ok, {ollama, <<"library">>, <<"llama3">>, <<"latest">>}},
        erllama_server_fetch_resolvers:parse(<<"ollama://library/llama3">>)
    ).

parse_ollama_with_tag_test() ->
    ?assertMatch(
        {ok, {ollama, <<"library">>, <<"llama3">>, <<"8b">>}},
        erllama_server_fetch_resolvers:parse(<<"ollama://library/llama3:8b">>)
    ).

parse_https_test() ->
    ?assertMatch(
        {ok, {http, <<"https://example.com/m.gguf">>}},
        erllama_server_fetch_resolvers:parse(<<"https://example.com/m.gguf">>)
    ).

parse_http_test() ->
    ?assertMatch(
        {ok, {http, <<"http://example.com/m.gguf">>}},
        erllama_server_fetch_resolvers:parse(<<"http://example.com/m.gguf">>)
    ).

parse_file_url_test() ->
    ?assertMatch(
        {ok, {file, <<"/abs/path">>}},
        erllama_server_fetch_resolvers:parse(<<"file:///abs/path">>)
    ).

parse_absolute_path_test() ->
    ?assertMatch(
        {ok, {file, <<"/srv/m.gguf">>}},
        erllama_server_fetch_resolvers:parse(<<"/srv/m.gguf">>)
    ).

parse_unknown_scheme_test() ->
    ?assertMatch(
        {error, {unsupported_spec, _}},
        erllama_server_fetch_resolvers:parse(<<"ftp://nope">>)
    ).

%% =============================================================================
%% resolve/1
%% =============================================================================

resolve_hf_url_shape_test() ->
    Parsed = {hf, <<"org">>, <<"repo">>, <<"path/to/f.gguf">>, <<"main">>},
    {ok, R} = erllama_server_fetch_resolvers:resolve(Parsed),
    ?assertEqual(
        <<"https://huggingface.co/org/repo/resolve/main/path/to/f.gguf">>, maps:get(url, R)
    ),
    ?assertEqual(<<"f.gguf">>, maps:get(out_basename, R)),
    Headers = maps:get(headers, R),
    %% Always carries User-Agent at minimum.
    ?assert(lists:any(fun({K, _}) -> K =:= <<"User-Agent">> end, Headers)).

resolve_hf_revision_in_url_test() ->
    Parsed = {hf, <<"a">>, <<"b">>, <<"c.gguf">>, <<"abc123">>},
    {ok, R} = erllama_server_fetch_resolvers:resolve(Parsed),
    ?assertEqual(<<"https://huggingface.co/a/b/resolve/abc123/c.gguf">>, maps:get(url, R)).

resolve_http_test() ->
    {ok, R} = erllama_server_fetch_resolvers:resolve({http, <<"https://e.com/m.gguf">>}),
    ?assertEqual(<<"https://e.com/m.gguf">>, maps:get(url, R)),
    ?assertEqual(<<"m.gguf">>, maps:get(out_basename, R)).

resolve_file_test() ->
    {ok, R} = erllama_server_fetch_resolvers:resolve({file, <<"/srv/m.gguf">>}),
    ?assertEqual(<<"/srv/m.gguf">>, maps:get(url, R)),
    ?assertEqual(<<"m.gguf">>, maps:get(out_basename, R)),
    ?assertEqual([], maps:get(headers, R)).

resolve_ollama_without_fetch_test() ->
    ?assertEqual(
        {error, ollama_needs_network},
        erllama_server_fetch_resolvers:resolve({ollama, <<"library">>, <<"llama3">>, <<"latest">>})
    ).

%% =============================================================================
%% resolve/2 (Ollama manifest)
%% =============================================================================

resolve_ollama_manifest_test() ->
    Manifest = ollama_manifest_fixture(),
    Fetch = fun(URL, _Hdrs) ->
        ?assertEqual(<<"https://registry.ollama.ai/v2/library/llama3/manifests/8b">>, URL),
        {ok, 200, [], Manifest}
    end,
    {ok, R} = erllama_server_fetch_resolvers:resolve(
        {ollama, <<"library">>, <<"llama3">>, <<"8b">>}, Fetch
    ),
    ?assertEqual(
        <<"https://registry.ollama.ai/v2/library/llama3/blobs/sha256:abc123">>,
        maps:get(url, R)
    ),
    ?assertEqual(<<"abc123">>, maps:get(expected_sha256, R)),
    ?assertEqual(<<"library-llama3-8b.gguf">>, maps:get(out_basename, R)).

resolve_ollama_no_model_layer_test() ->
    Manifest = iolist_to_binary(
        json:encode(#{
            <<"schemaVersion">> => 2,
            <<"layers">> => [
                #{
                    <<"mediaType">> => <<"application/vnd.ollama.image.template">>,
                    <<"digest">> => <<"sha256:1">>
                }
            ]
        })
    ),
    Fetch = fun(_URL, _Hdrs) -> {ok, 200, [], Manifest} end,
    ?assertMatch(
        {error, ollama_no_model_layer},
        erllama_server_fetch_resolvers:resolve(
            {ollama, <<"library">>, <<"x">>, <<"latest">>}, Fetch
        )
    ).

resolve_ollama_bad_manifest_test() ->
    Fetch = fun(_, _) -> {ok, 200, [], <<"not json">>} end,
    ?assertMatch(
        {error, _},
        erllama_server_fetch_resolvers:resolve(
            {ollama, <<"library">>, <<"x">>, <<"latest">>}, Fetch
        )
    ).

resolve_ollama_404_test() ->
    Fetch = fun(_, _) -> {ok, 404, [], <<>>} end,
    ?assertMatch(
        {error, {ollama_manifest_status, 404}},
        erllama_server_fetch_resolvers:resolve(
            {ollama, <<"library">>, <<"x">>, <<"latest">>}, Fetch
        )
    ).

%% =============================================================================
%% HF siblings + GGUF pick
%% =============================================================================

hf_list_siblings_test() ->
    Body = iolist_to_binary(
        json:encode(#{
            <<"siblings">> => [
                #{<<"rfilename">> => <<"README.md">>},
                #{<<"rfilename">> => <<"model.Q4_K_M.gguf">>},
                #{<<"rfilename">> => <<"model.Q8_0.gguf">>}
            ]
        })
    ),
    Fetch = fun(URL, _Hdrs) ->
        ?assertEqual(
            <<"https://huggingface.co/api/models/org/repo/revision/main">>,
            URL
        ),
        {ok, 200, [], Body}
    end,
    {ok, Files} = erllama_server_fetch_resolvers:hf_list_siblings(
        <<"org">>, <<"repo">>, <<"main">>, Fetch
    ),
    ?assertEqual(
        [<<"README.md">>, <<"model.Q4_K_M.gguf">>, <<"model.Q8_0.gguf">>],
        Files
    ).

hf_list_siblings_404_test() ->
    Fetch = fun(_, _) -> {ok, 404, [], <<>>} end,
    ?assertMatch(
        {error, {hf_repo_not_found, <<"o">>, <<"r">>, <<"main">>}},
        erllama_server_fetch_resolvers:hf_list_siblings(<<"o">>, <<"r">>, <<"main">>, Fetch)
    ).

hf_pick_gguf_prefers_q4_k_m_test() ->
    Files = [
        <<"README.md">>,
        <<"model.Q8_0.gguf">>,
        <<"model.Q4_K_M.gguf">>,
        <<"model.Q4_0.gguf">>
    ],
    ?assertEqual(
        {ok, <<"model.Q4_K_M.gguf">>},
        erllama_server_fetch_resolvers:hf_pick_gguf(Files)
    ).

hf_pick_gguf_falls_back_to_first_test() ->
    Files = [<<"a.gguf">>, <<"b.gguf">>],
    ?assertMatch({ok, _}, erllama_server_fetch_resolvers:hf_pick_gguf(Files)).

hf_pick_gguf_no_gguf_test() ->
    ?assertEqual(
        {error, no_gguf},
        erllama_server_fetch_resolvers:hf_pick_gguf([<<"README.md">>, <<"config.json">>])
    ).

%% =============================================================================
%% spec_canonical / spec_hash
%% =============================================================================

spec_hash_stable_test() ->
    P = {hf, <<"a">>, <<"b">>, <<"c.gguf">>, <<"main">>},
    H1 = erllama_server_fetch_resolvers:spec_hash(P),
    H2 = erllama_server_fetch_resolvers:spec_hash(P),
    ?assertEqual(H1, H2),
    ?assertEqual(16, byte_size(H1)).

spec_hash_unique_test() ->
    H1 = erllama_server_fetch_resolvers:spec_hash(
        {hf, <<"a">>, <<"b">>, <<"c">>, <<"main">>}
    ),
    H2 = erllama_server_fetch_resolvers:spec_hash(
        {hf, <<"a">>, <<"b">>, <<"d">>, <<"main">>}
    ),
    ?assertNotEqual(H1, H2).

%% =============================================================================
%% Fixtures
%% =============================================================================

ollama_manifest_fixture() ->
    iolist_to_binary(
        json:encode(#{
            <<"schemaVersion">> => 2,
            <<"mediaType">> => <<"application/vnd.docker.distribution.manifest.v2+json">>,
            <<"config">> => #{
                <<"mediaType">> => <<"application/vnd.docker.container.image.v1+json">>,
                <<"digest">> => <<"sha256:cfg">>,
                <<"size">> => 1234
            },
            <<"layers">> => [
                #{
                    <<"mediaType">> => <<"application/vnd.ollama.image.template">>,
                    <<"digest">> => <<"sha256:tpl">>,
                    <<"size">> => 200
                },
                #{
                    <<"mediaType">> => <<"application/vnd.ollama.image.model">>,
                    <<"digest">> => <<"sha256:abc123">>,
                    <<"size">> => 999999
                }
            ]
        })
    ).
