%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_models_SUITE).

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
    pull_leaves_loader_untouched_when_no_markers/1,
    pull_detects_think_tag_thinking_markers/1,
    pull_detects_thinking_tag_thinking_markers/1,
    pull_leaves_thinking_markers_unset_when_no_tags/1,
    pull_caps_large_context/1,
    pull_detects_embedding_model/1,
    pull_coordinator_persists_after_subscriber_dies/1,
    pull_coordinator_reports_success_to_subscriber/1,
    pull_coordinator_persist_error_reports_error/1
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
        pull_leaves_loader_untouched_when_no_markers,
        pull_detects_think_tag_thinking_markers,
        pull_detects_thinking_tag_thinking_markers,
        pull_leaves_thinking_markers_unset_when_no_tags,
        pull_caps_large_context,
        pull_detects_embedding_model,
        pull_coordinator_persists_after_subscriber_dies,
        pull_coordinator_reports_success_to_subscriber,
        pull_coordinator_persist_error_reports_error
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_) ->
    ok.

init_per_testcase(_, Config) ->
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    ok = filelib:ensure_path(Cache),
    application:set_env(barrel_inference_server, model_cache_dir, Cache),
    %% Synthetic GGUF blob the file:// passthrough can resolve.
    Blob = filename:join(Cwd, "synthetic.gguf"),
    ok = file:write_file(Blob, synthetic_gguf()),
    [{cwd, Cwd}, {cache, Cache}, {blob, Blob} | Config].

end_per_testcase(_, Config) ->
    Cwd = ?config(cwd, Config),
    application:unset_env(barrel_inference_server, model_cache_dir),
    os:cmd("rm -rf " ++ Cwd),
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

list_empty(_Config) ->
    ?assertEqual([], barrel_inference_server_models:list()).

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
    {ok, M} = barrel_inference_server_models:show(<<"showme:v1">>),
    ?assertEqual(<<"showme">>, maps:get(<<"name">>, M)),
    ?assertEqual(<<"v1">>, maps:get(<<"tag">>, M)).

delete_removes_manifest(Config) ->
    {ok, _} = pull_synthetic(Config, <<"deleteme">>, <<"latest">>),
    ?assertMatch({ok, _}, barrel_inference_server_models:get(<<"deleteme">>)),
    ok = barrel_inference_server_models:delete(<<"deleteme">>),
    ?assertEqual({error, not_found}, barrel_inference_server_models:get(<<"deleteme">>)),
    %% Blob is preserved (other tags may reference it).
    Blob = ?config(blob, Config),
    ?assert(filelib:is_regular(Blob)).

delete_unknown_returns_not_found(_Config) ->
    ?assertEqual({error, not_found}, barrel_inference_server_models:delete(<<"unknown:tag">>)).

copy_creates_alias(Config) ->
    {ok, Original} = pull_synthetic(Config, <<"orig">>, <<"latest">>),
    ok = barrel_inference_server_models:copy(<<"orig">>, <<"alias:v1">>),
    {ok, Alias} = barrel_inference_server_models:get(<<"alias:v1">>),
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
    Names = [maps:get(<<"name">>, M) || M <- barrel_inference_server_models:list()],
    ?assert(lists:member(<<"orig">>, Names)),
    ?assert(lists:member(<<"alias">>, Names)).

pull_short_name_wraps_to_ollama(_Config) ->
    {ok, Spec, Name, Tag} = barrel_inference_server_models:resolve_spec(<<"llama3">>),
    ?assertEqual(<<"ollama://library/llama3:latest">>, Spec),
    ?assertEqual(<<"llama3">>, Name),
    ?assertEqual(<<"latest">>, Tag),
    {ok, Spec2, Name2, Tag2} = barrel_inference_server_models:resolve_spec(<<"llama3:8b">>),
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

%% Auto-detect of `thinking_markers' from the chat_template at pull
%% time. Two families: `<think>' (Qwen3 / QwQ / DeepSeek-R1 lineage)
%% and `<thinking>' (Claude-distilled lookalikes). With markers
%% set, the engine routes reasoning tokens to dedicated
%% barrel_inference_reasoning_token messages instead of leaking them into
%% the visible content block.

pull_detects_think_tag_thinking_markers(Config) ->
    Template = <<"...<think>{ chain of thought }</think>...">>,
    Loader = pull_loader_with_template(Config, Template, <<"qwen3-fake">>),
    Markers = maps:get(<<"thinking_markers">>, Loader),
    ?assertEqual(<<"<think>">>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"</think>">>, maps:get(<<"end">>, Markers)).

pull_detects_thinking_tag_thinking_markers(Config) ->
    Template = <<"...<thinking>{ chain of thought }</thinking>...">>,
    Loader = pull_loader_with_template(Config, Template, <<"claude-fake">>),
    Markers = maps:get(<<"thinking_markers">>, Loader),
    ?assertEqual(<<"<thinking>">>, maps:get(<<"start">>, Markers)),
    ?assertEqual(<<"</thinking>">>, maps:get(<<"end">>, Markers)).

pull_leaves_thinking_markers_unset_when_no_tags(Config) ->
    %% Generic template with no thinking tag; the loader stays free
    %% of `thinking_markers' so the engine treats reasoning text
    %% (if any) as regular output.
    Template = <<"{% for x in y %}{{ x }}{% endfor %}">>,
    Loader = pull_loader_with_template(Config, Template, <<"generic-think-fake">>),
    ?assertNot(maps:is_key(<<"thinking_markers">>, Loader)).

resolve_spec_for_known_schemes(_Config) ->
    {ok, Spec1, N1, T1} = barrel_inference_server_models:resolve_spec(<<"hf://Org/Repo/x.gguf">>),
    ?assertEqual(<<"hf://Org/Repo/x.gguf">>, Spec1),
    ?assertEqual(<<"Org/Repo">>, N1),
    ?assertEqual(<<"main">>, T1),
    {ok, Spec2, N2, T2} = barrel_inference_server_models:resolve_spec(
        <<"ollama://custom-lib/model:tag1">>
    ),
    ?assertEqual(<<"ollama://custom-lib/model:tag1">>, Spec2),
    ?assertEqual(<<"custom-lib/model">>, N2),
    ?assertEqual(<<"tag1">>, T2),
    {ok, _, N3, T3} = barrel_inference_server_models:resolve_spec(
        <<"https://e.com/foo/bar.gguf">>
    ),
    ?assertEqual(<<"bar">>, N3),
    ?assertEqual(<<"latest">>, T3).

%% A model that advertises a huge native context must not bake that as the
%% pulled load default (it would allocate tens of GB of KV); cap_ctx/1 clamps
%% context_size and loader.n_ctx to DEFAULT_PULL_MAX_CTX (32768).
pull_caps_large_context(Config) ->
    Cwd = ?config(cwd, Config),
    Path = filename:join(Cwd, "bigctx.gguf"),
    ok = file:write_file(Path, synthetic_gguf(<<"{{ x }}">>, 262144)),
    Spec = list_to_binary("file://" ++ Path),
    {ok, M} = barrel_inference_server_models:pull(Spec, #{
        name => <<"bigctx">>, tag => <<"latest">>
    }),
    ?assertEqual(32768, maps:get(<<"context_size">>, M)),
    ?assertEqual(32768, maps:get(<<"n_ctx">>, maps:get(<<"loader">>, M))).

%% An embedding GGUF (declared pooling type) is flagged in the manifest so
%% the loader opens its context in embeddings mode.
pull_detects_embedding_model(Config) ->
    Cwd = ?config(cwd, Config),
    Path = filename:join(Cwd, "embed.gguf"),
    ok = file:write_file(Path, embed_gguf()),
    Spec = list_to_binary("file://" ++ Path),
    {ok, M} = barrel_inference_server_models:pull(Spec, #{
        name => <<"embed">>, tag => <<"latest">>
    }),
    ?assertEqual(true, maps:get(<<"embeddings">>, maps:get(<<"loader">>, M))).

%% The pull coordinator (barrel_inference_server_pull) owns the fetch +
%% manifest persistence so a completed download always registers, even
%% if the HTTP handler that requested it has gone away. A file:// spec
%% resolves as a cache hit, so the coordinator can run without the fetch
%% srv; we start it directly via start_link/5.

pull_coordinator_persists_after_subscriber_dies(Config) ->
    Spec = file_spec(Config),
    %% Only subscriber is a pid that is already dead before the
    %% coordinator emits anything (models the handler that timed out).
    Dead = spawn(fun() -> ok end),
    wait_down(Dead),
    {ok, Coord} = barrel_inference_server_pull:start_link(
        Spec, <<"coord-survivor">>, <<"latest">>, #{}, [Dead]
    ),
    ok = wait_down(Coord),
    {ok, M} = barrel_inference_server_models:get(<<"coord-survivor">>),
    ?assertEqual(<<"coord-survivor">>, maps:get(<<"name">>, M)),
    ?assertEqual(<<"latest">>, maps:get(<<"tag">>, M)).

pull_coordinator_reports_success_to_subscriber(Config) ->
    Spec = file_spec(Config),
    {ok, Coord} = barrel_inference_server_pull:start_link(
        Spec, <<"sub-model">>, <<"v9">>, #{}, [self()]
    ),
    Events = collect_events(Coord, []),
    ?assert(lists:member({status, <<"verifying sha256 digest">>}, Events)),
    ?assert(lists:member({status, <<"writing manifest">>}, Events)),
    ?assert(
        lists:any(
            fun
                ({success, _}) -> true;
                (_) -> false
            end,
            Events
        )
    ),
    {ok, M} = barrel_inference_server_models:get(<<"sub-model:v9">>),
    ?assertEqual(<<"sub-model">>, maps:get(<<"name">>, M)).

pull_coordinator_persist_error_reports_error(Config) ->
    %% A read-only cache makes the manifest write fail; the coordinator
    %% must report an error event (not crash) and register nothing.
    RoCache = filename:join(?config(cwd, Config), "ro_cache"),
    ok = file:make_dir(RoCache),
    ok = file:change_mode(RoCache, 8#500),
    application:set_env(barrel_inference_server, model_cache_dir, RoCache),
    try
        Spec = file_spec(Config),
        {ok, Coord} = barrel_inference_server_pull:start_link(
            Spec, <<"err-model">>, <<"latest">>, #{}, [self()]
        ),
        ok = await_error(Coord),
        ?assertEqual([], barrel_inference_server_models:list())
    after
        %% Restore perms so end_per_testcase's rm -rf can clean up.
        file:change_mode(RoCache, 8#700)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

file_spec(Config) ->
    list_to_binary("file://" ++ ?config(blob, Config)).

wait_down(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        ct:fail({coordinator_timeout, Pid})
    end.

collect_events(Coord, Acc) ->
    receive
        {pull_event, Coord, {success, M}} ->
            lists:reverse([{success, M} | Acc]);
        {pull_event, Coord, {error, R}} ->
            lists:reverse([{error, R} | Acc]);
        {pull_event, Coord, Ev} ->
            collect_events(Coord, [Ev | Acc])
    after 5000 ->
        ct:fail(coordinator_timeout)
    end.

await_error(Coord) ->
    receive
        {pull_event, Coord, {error, _}} -> ok;
        {pull_event, Coord, _Other} -> await_error(Coord)
    after 5000 ->
        ct:fail(no_error_event)
    end.

pull_synthetic(Config, Name, Tag) ->
    Blob = ?config(blob, Config),
    Spec = list_to_binary("file://" ++ Blob),
    barrel_inference_server_models:pull(Spec, #{name => Name, tag => Tag}).

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
    {ok, Manifest} = barrel_inference_server_models:pull(
        Spec, #{name => Name, tag => <<"latest">>}
    ),
    maps:get(<<"loader">>, Manifest).

%% Build a synthetic GGUF v3 binary with the metadata fields the
%% suite asserts on. Mirrors the encoders in
%% barrel_inference_server_gguf_tests so the registry pull pipeline sees a
%% real GGUF without depending on a downloaded model.
synthetic_gguf() ->
    synthetic_gguf(<<"{% for x in y %}{{ x }}{% endfor %}">>).

synthetic_gguf(Template) ->
    synthetic_gguf(Template, 4096).

synthetic_gguf(Template, CtxLen) ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen2">>},
        {<<"qwen2.context_length">>, ?T_UINT32, CtxLen},
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

%% A minimal embedding-model GGUF: bidirectional arch + a declared pooling
%% type, which barrel_inference_server_gguf:is_embedding_model/1 detects.
embed_gguf() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"nomic-bert">>},
        {<<"nomic-bert.context_length">>, ?T_UINT32, 2048},
        {<<"nomic-bert.embedding_length">>, ?T_UINT32, 768},
        {<<"nomic-bert.pooling_type">>, ?T_UINT32, 1},
        {<<"general.file_type">>, ?T_UINT32, 15},
        {<<"tokenizer.ggml.model">>, ?T_STRING, <<"bert">>}
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
        "barrel_inference_server_models_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
