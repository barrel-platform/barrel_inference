%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_models_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    suite/0,
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    list_empty/1,
    pull_creates_manifest/1,
    pull_carries_gguf_fields/1,
    show_returns_manifest/1,
    delete_removes_manifest/1,
    delete_unknown_returns_not_found/1,
    copy_creates_alias/1,
    pull_short_name_wraps_to_ollama/1,
    resolve_spec_for_known_schemes/1,
    pull_detects_qwen_xml_tool_call_format/1,
    pull_detects_dsml_tool_call_format/1,
    pull_detects_llama_python_tag_tool_call_format/1,
    pull_detects_mistral_tool_call_format/1,
    pull_leaves_loader_untouched_when_no_markers/1
]).

%% GGUF value type tags (mirroring the gguf parser).
-define(T_UINT32, 4).
-define(T_FLOAT32, 6).
-define(T_BOOL, 7).
-define(T_STRING, 8).

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [
        list_empty,
        pull_creates_manifest,
        pull_carries_gguf_fields,
        show_returns_manifest,
        delete_removes_manifest,
        delete_unknown_returns_not_found,
        copy_creates_alias,
        pull_short_name_wraps_to_ollama,
        resolve_spec_for_known_schemes,
        pull_detects_qwen_xml_tool_call_format,
        pull_detects_dsml_tool_call_format,
        pull_detects_llama_python_tag_tool_call_format,
        pull_detects_mistral_tool_call_format,
        pull_leaves_loader_untouched_when_no_markers
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_) ->
    ok.

init_per_testcase(_, Config) ->
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    ok = filelib:ensure_path(Cache),
    application:set_env(erllama_server, model_cache_dir, Cache),
    %% Synthetic GGUF blob the file:// passthrough can resolve.
    Blob = filename:join(Cwd, "synthetic.gguf"),
    ok = file:write_file(Blob, synthetic_gguf()),
    [{cwd, Cwd}, {cache, Cache}, {blob, Blob} | Config].

end_per_testcase(_, Config) ->
    Cwd = ?config(cwd, Config),
    application:unset_env(erllama_server, model_cache_dir),
    os:cmd("rm -rf " ++ Cwd),
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

list_empty(_Config) ->
    ?assertEqual([], erllama_server_models:list()).

pull_creates_manifest(Config) ->
    {ok, Manifest} = pull_synthetic(Config, <<"test-model">>, <<"latest">>),
    ?assertEqual(<<"test-model">>, maps:get(<<"name">>, Manifest)),
    ?assertEqual(<<"latest">>, maps:get(<<"tag">>, Manifest)),
    ?assertEqual(<<"gguf">>, maps:get(<<"format">>, Manifest)),
    BlobPath = ?config(blob, Config),
    ?assertEqual(list_to_binary(BlobPath), maps:get(<<"blob_path">>, Manifest)),
    ?assert(maps:get(<<"size_bytes">>, Manifest) > 0),
    ?assertMatch(<<"sha256:", _/binary>>, maps:get(<<"digest">>, Manifest)).

pull_carries_gguf_fields(Config) ->
    {ok, Manifest} = pull_synthetic(Config, <<"test-model">>, <<"latest">>),
    ?assertEqual(<<"qwen2">>, maps:get(<<"architecture">>, Manifest)),
    ?assertEqual(<<"qwen">>, maps:get(<<"family">>, Manifest)),
    ?assertEqual(<<"q4_k_m">>, maps:get(<<"quantization">>, Manifest)),
    ?assertEqual(4096, maps:get(<<"context_size">>, Manifest)),
    Loader = maps:get(<<"loader">>, Manifest),
    ?assertEqual(4096, maps:get(<<"n_ctx">>, Loader)),
    ?assertEqual(<<"q4_k_m">>, maps:get(<<"quant_type">>, Loader)),
    ?assertEqual(4, maps:get(<<"quant_bits">>, Loader)).

show_returns_manifest(Config) ->
    {ok, _} = pull_synthetic(Config, <<"showme">>, <<"v1">>),
    {ok, M} = erllama_server_models:show(<<"showme:v1">>),
    ?assertEqual(<<"showme">>, maps:get(<<"name">>, M)),
    ?assertEqual(<<"v1">>, maps:get(<<"tag">>, M)).

delete_removes_manifest(Config) ->
    {ok, _} = pull_synthetic(Config, <<"deleteme">>, <<"latest">>),
    ?assertMatch({ok, _}, erllama_server_models:get(<<"deleteme">>)),
    ok = erllama_server_models:delete(<<"deleteme">>),
    ?assertEqual({error, not_found}, erllama_server_models:get(<<"deleteme">>)),
    %% Blob is preserved (other tags may reference it).
    Blob = ?config(blob, Config),
    ?assert(filelib:is_regular(Blob)).

delete_unknown_returns_not_found(_Config) ->
    ?assertEqual({error, not_found}, erllama_server_models:delete(<<"unknown:tag">>)).

copy_creates_alias(Config) ->
    {ok, Original} = pull_synthetic(Config, <<"orig">>, <<"latest">>),
    ok = erllama_server_models:copy(<<"orig">>, <<"alias:v1">>),
    {ok, Alias} = erllama_server_models:get(<<"alias:v1">>),
    ?assertEqual(<<"alias">>, maps:get(<<"name">>, Alias)),
    ?assertEqual(<<"v1">>, maps:get(<<"tag">>, Alias)),
    %% Same blob digest underneath.
    ?assertEqual(
        maps:get(<<"digest">>, Original),
        maps:get(<<"digest">>, Alias)
    ),
    ?assertEqual(
        maps:get(<<"blob_path">>, Original),
        maps:get(<<"blob_path">>, Alias)
    ),
    %% Both manifests are listed.
    Names = [maps:get(<<"name">>, M) || M <- erllama_server_models:list()],
    ?assert(lists:member(<<"orig">>, Names)),
    ?assert(lists:member(<<"alias">>, Names)).

pull_short_name_wraps_to_ollama(_Config) ->
    {ok, Spec, Name, Tag} = erllama_server_models:resolve_spec(<<"llama3">>),
    ?assertEqual(<<"ollama://library/llama3:latest">>, Spec),
    ?assertEqual(<<"llama3">>, Name),
    ?assertEqual(<<"latest">>, Tag),
    {ok, Spec2, Name2, Tag2} = erllama_server_models:resolve_spec(<<"llama3:8b">>),
    ?assertEqual(<<"ollama://library/llama3:8b">>, Spec2),
    ?assertEqual(<<"llama3">>, Name2),
    ?assertEqual(<<"8b">>, Tag2).

%% Auto-detect of tool_call_markers from the chat_template at pull
%% time. The four common families - Qwen, DeepSeek, Llama-3,
%% Mistral - each have a distinctive marker substring; the autodetect
%% writes the matching `tool_call_format' + `tool_call_markers' into
%% the manifest's loader sub-map. Templates that match none leave
%% the loader untouched so the engine falls back to the legacy GBNF
%% grammar.

pull_detects_qwen_xml_tool_call_format(Config) ->
    Template = <<"...<tool_call>{ name, args }</tool_call>...">>,
    Loader = pull_loader_with_template(Config, Template, <<"qwen-fake">>),
    ?assertEqual(<<"qwen-xml">>, maps:get(<<"tool_call_format">>, Loader)),
    Markers = maps:get(<<"tool_call_markers">>, Loader),
    ?assertEqual(<<"<tool_call>">>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"</tool_call>">>, maps:get(<<"end">>, Markers)).

pull_detects_dsml_tool_call_format(Config) ->
    Template = <<"...<｜tool▁call▁begin｜>{...}<｜tool▁call▁end｜>..."/utf8>>,
    Loader = pull_loader_with_template(Config, Template, <<"dsml-fake">>),
    ?assertEqual(<<"dsml">>, maps:get(<<"tool_call_format">>, Loader)),
    Markers = maps:get(<<"tool_call_markers">>, Loader),
    ?assertEqual(<<"<｜tool▁call▁begin｜>"/utf8>>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"<｜tool▁call▁end｜>"/utf8>>, maps:get(<<"end">>, Markers)).

pull_detects_llama_python_tag_tool_call_format(Config) ->
    Template = <<"... <|python_tag|>foo(bar)<|eom_id|> ...">>,
    Loader = pull_loader_with_template(Config, Template, <<"llama-fake">>),
    ?assertEqual(<<"llama-python-tag">>, maps:get(<<"tool_call_format">>, Loader)),
    Markers = maps:get(<<"tool_call_markers">>, Loader),
    ?assertEqual(<<"<|python_tag|>">>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"<|eom_id|>">>, maps:get(<<"end">>, Markers)).

pull_detects_mistral_tool_call_format(Config) ->
    Template = <<"... [TOOL_CALLS][{...}] ...">>,
    Loader = pull_loader_with_template(Config, Template, <<"mistral-fake">>),
    ?assertEqual(<<"mistral-tool-calls">>, maps:get(<<"tool_call_format">>, Loader)),
    Markers = maps:get(<<"tool_call_markers">>, Loader),
    ?assertEqual(<<"[TOOL_CALLS]">>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"</s>">>, maps:get(<<"end">>, Markers)).

pull_leaves_loader_untouched_when_no_markers(Config) ->
    %% Generic template that doesn't contain any known marker
    %% substring; the loader stays free of `tool_call_*' keys so the
    %% engine uses the GBNF fallback.
    Template = <<"{% for x in y %}{{ x }}{% endfor %}">>,
    Loader = pull_loader_with_template(Config, Template, <<"generic-fake">>),
    ?assertNot(maps:is_key(<<"tool_call_format">>, Loader)),
    ?assertNot(maps:is_key(<<"tool_call_markers">>, Loader)).

resolve_spec_for_known_schemes(_Config) ->
    {ok, Spec1, N1, T1} = erllama_server_models:resolve_spec(<<"hf://Org/Repo/x.gguf">>),
    ?assertEqual(<<"hf://Org/Repo/x.gguf">>, Spec1),
    ?assertEqual(<<"Org/Repo">>, N1),
    ?assertEqual(<<"main">>, T1),
    {ok, Spec2, N2, T2} = erllama_server_models:resolve_spec(
        <<"ollama://custom-lib/model:tag1">>
    ),
    ?assertEqual(<<"ollama://custom-lib/model:tag1">>, Spec2),
    ?assertEqual(<<"custom-lib/model">>, N2),
    ?assertEqual(<<"tag1">>, T2),
    {ok, _, N3, T3} = erllama_server_models:resolve_spec(
        <<"https://e.com/foo/bar.gguf">>
    ),
    ?assertEqual(<<"bar">>, N3),
    ?assertEqual(<<"latest">>, T3).

%% =============================================================================
%% Helpers
%% =============================================================================

pull_synthetic(Config, Name, Tag) ->
    Blob = ?config(blob, Config),
    Spec = list_to_binary("file://" ++ Blob),
    erllama_server_models:pull(Spec, #{name => Name, tag => Tag}).

%% Write a fresh synthetic GGUF with a caller-supplied chat_template
%% and pull it. Returns the `loader' sub-map for the assert sites
%% above. Each test gets its own blob path (per Name) so different
%% templates hash to different blob files.
pull_loader_with_template(Config, Template, Name) ->
    Cwd = ?config(cwd, Config),
    BlobName = binary_to_list(Name) ++ ".gguf",
    Path = filename:join(Cwd, BlobName),
    ok = file:write_file(Path, synthetic_gguf(Template)),
    Spec = list_to_binary("file://" ++ Path),
    {ok, Manifest} = erllama_server_models:pull(
        Spec, #{name => Name, tag => <<"latest">>}
    ),
    maps:get(<<"loader">>, Manifest).

%% Build a synthetic GGUF v3 binary with the metadata fields the
%% suite asserts on. Mirrors the encoders in
%% erllama_server_gguf_tests so the registry pull pipeline sees a
%% real GGUF without depending on a downloaded model.
synthetic_gguf() ->
    synthetic_gguf(<<"{% for x in y %}{{ x }}{% endfor %}">>).

synthetic_gguf(Template) ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen2">>},
        {<<"qwen2.context_length">>, ?T_UINT32, 4096},
        {<<"qwen2.embedding_length">>, ?T_UINT32, 4096},
        {<<"general.file_type">>, ?T_UINT32, 15},
        {<<"general.size_label">>, ?T_STRING, <<"7B">>},
        {<<"general.use_eos">>, ?T_BOOL, true},
        {<<"general.temperature">>, ?T_FLOAT32, 0.8},
        {<<"tokenizer.chat_template">>, ?T_STRING, Template},
        {<<"tokenizer.ggml.model">>, ?T_STRING, <<"gpt2">>}
    ],
    Body = iolist_to_binary([encode_kv(K, T, V) || {K, T, V} <- KVs]),
    <<"GGUF", 3:32/little, 0:64/little, (length(KVs)):64/little, Body/binary>>.

encode_kv(Key, Type, Value) ->
    <<(encode_string(Key))/binary, Type:32/little, (encode_value(Type, Value))/binary>>.

encode_value(?T_UINT32, V) -> <<V:32/little-unsigned>>;
encode_value(?T_FLOAT32, V) -> <<V:32/little-float>>;
encode_value(?T_BOOL, true) -> <<1:8>>;
encode_value(?T_BOOL, false) -> <<0:8>>;
encode_value(?T_STRING, V) -> encode_string(V).

encode_string(Bin) ->
    <<(byte_size(Bin)):64/little-unsigned, Bin/binary>>.

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_models_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
