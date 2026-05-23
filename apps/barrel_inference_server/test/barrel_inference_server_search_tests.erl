%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_search_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% HF backend
%% =============================================================================

hf_search_url_includes_query_and_filter_test() ->
    Self = self(),
    Fetch = fun(URL, _Hdrs) ->
        Self ! {url, URL},
        {ok, 200, [], <<"[]">>}
    end,
    {ok, []} = barrel_inference_server_search_hf:search(<<"llama">>, #{limit => 5}, Fetch),
    receive
        {url, URL} ->
            ?assert(binary:match(URL, <<"search=llama">>) =/= nomatch),
            ?assert(binary:match(URL, <<"limit=5">>) =/= nomatch),
            ?assert(binary:match(URL, <<"filter=gguf">>) =/= nomatch),
            ?assert(binary:match(URL, <<"full=true">>) =/= nomatch)
    after 100 ->
        ?assert(false)
    end.

hf_search_filter_any_omits_param_test() ->
    Self = self(),
    Fetch = fun(URL, _Hdrs) ->
        Self ! {url, URL},
        {ok, 200, [], <<"[]">>}
    end,
    barrel_inference_server_search_hf:search(<<"x">>, #{hf_filter => any}, Fetch),
    receive
        {url, URL} ->
            ?assertEqual(nomatch, binary:match(URL, <<"filter=">>))
    after 100 ->
        ?assert(false)
    end.

hf_search_returns_unified_hits_test() ->
    Body = iolist_to_binary(
        json:encode([
            #{
                <<"id">> => <<"TheBloke/Llama-2-7B-Chat-GGUF">>,
                <<"description">> => <<"chat tuned">>,
                <<"downloads">> => 12345,
                <<"lastModified">> => <<"2025-01-01">>,
                <<"tags">> => [<<"text-generation">>, <<"gguf">>],
                <<"siblings">> => [
                    #{<<"rfilename">> => <<"README.md">>},
                    #{<<"rfilename">> => <<"llama-2-7b-chat.Q4_K_M.gguf">>}
                ]
            }
        ])
    ),
    Fetch = fun(_, _) -> {ok, 200, [], Body} end,
    {ok, [Hit]} = barrel_inference_server_search_hf:search(<<"llama">>, #{}, Fetch),
    ?assertEqual(hf, maps:get(source, Hit)),
    ?assertEqual(<<"hf://TheBloke/Llama-2-7B-Chat-GGUF">>, maps:get(id, Hit)),
    ?assertEqual(12345, maps:get(downloads, Hit)),
    [File] = maps:get(files, Hit),
    ?assertEqual(
        <<"hf://TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b-chat.Q4_K_M.gguf">>,
        maps:get(id, File)
    ).

hf_search_404_test() ->
    Fetch = fun(_, _) -> {ok, 404, [], <<>>} end,
    ?assertMatch(
        {error, {hf_search_status, 404}},
        barrel_inference_server_search_hf:search(<<"x">>, #{}, Fetch)
    ).

%% =============================================================================
%% Ollama backend
%% =============================================================================

ollama_search_substring_match_test() ->
    Body = iolist_to_binary(
        json:encode(#{
            <<"repositories">> => [
                <<"library/llama2">>,
                <<"library/llama3">>,
                <<"library/codellama">>,
                <<"library/phi3">>
            ]
        })
    ),
    Fetch = fun(_, _) -> {ok, 200, [], Body} end,
    {ok, Hits} = barrel_inference_server_search_ollama:search(<<"llama">>, #{limit => 10}, Fetch),
    Names = [maps:get(name, H) || H <- Hits],
    ?assertEqual(
        [<<"library/llama2">>, <<"library/llama3">>, <<"library/codellama">>],
        Names
    ),
    ?assertEqual(ollama, maps:get(source, hd(Hits))),
    ?assertEqual(<<"ollama://library/llama2">>, maps:get(id, hd(Hits))).

ollama_search_limit_test() ->
    Body = iolist_to_binary(
        json:encode(#{
            <<"repositories">> => [
                <<"library/llama1">>, <<"library/llama2">>, <<"library/llama3">>
            ]
        })
    ),
    Fetch = fun(_, _) -> {ok, 200, [], Body} end,
    {ok, Hits} = barrel_inference_server_search_ollama:search(<<"llama">>, #{limit => 2}, Fetch),
    ?assertEqual(2, length(Hits)).

ollama_search_empty_query_returns_all_test() ->
    Body = iolist_to_binary(
        json:encode(#{
            <<"repositories">> => [<<"library/a">>, <<"library/b">>]
        })
    ),
    Fetch = fun(_, _) -> {ok, 200, [], Body} end,
    {ok, Hits} = barrel_inference_server_search_ollama:search(<<>>, #{}, Fetch),
    ?assertEqual(2, length(Hits)).

ollama_search_404_test() ->
    Fetch = fun(_, _) -> {ok, 404, [], <<>>} end,
    ?assertMatch(
        {error, {ollama_catalog_status, 404}},
        barrel_inference_server_search_ollama:search(<<"x">>, #{}, Fetch)
    ).
