%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_loader_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% manifest_to_config/1
%% =============================================================================

manifest_to_config_basic_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:6a01">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual("/blobs/sha256-6a01.gguf", maps:get(model_path, Config)),
    ?assertEqual(q4_k_m, maps:get(quant_type, Config)),
    ?assertEqual(4, maps:get(quant_bits, Config)),
    ?assertEqual(4096, maps:get(context_size, Config)),
    ?assert(is_binary(maps:get(fingerprint, Config))).

manifest_to_config_caps_context_size_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:6a01">>, <<"q4_k_m">>, 131072, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(4096, maps:get(context_size, Config)).

manifest_to_config_defaults_when_missing_test() ->
    Manifest = #{
        <<"name">> => <<"x">>,
        <<"tag">> => <<"latest">>,
        <<"blob_path">> => <<"/blob.gguf">>
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual("/blob.gguf", maps:get(model_path, Config)),
    ?assertEqual(f16, maps:get(quant_type, Config)),
    ?assertEqual(4, maps:get(quant_bits, Config)),
    ?assertEqual(4096, maps:get(context_size, Config)).

manifest_to_config_fingerprint_padding_test() ->
    %% A short hex digest decodes to <32 bytes; the fallback zero
    %% fingerprint kicks in.
    Manifest = manifest(<<"sha256:abcd">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(32, byte_size(maps:get(fingerprint, Config))).

%% barrel_inference_model_llama reads context_opts/model_opts and forwards them
%% to the NIF. Without n_ctx wired through, llama.cpp falls back to
%% 512 and segfaults on any input larger than that. Regression for
%% the segfault hit while pointing Claude Code at the daemon.
manifest_to_config_passes_n_ctx_to_context_opts_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:0001">>, <<"q4_k_m">>, 8192, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    %% Capped at max_context_size.
    ?assertEqual(4096, maps:get(n_ctx, CtxOpts)),
    %% n_batch falls through from the manifest's loader.n_batch when
    %% set; auto-derives from parameter_size otherwise (2048 fallback
    %% when neither is present).
    ?assert(is_integer(maps:get(n_batch, CtxOpts))).

%% barrel_inference 0.8.0 decode_budget_ms threads into context_opts.
%% `loader.decode_budget_ms' is forwarded as-is.
manifest_to_config_decode_budget_from_loader_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    application:unset_env(barrel_inference_server, decode_budget_ms),
    Manifest = with_loader_keys(
        manifest(<<"sha256:0010">>, <<"q4_k_m">>, 4096, 4),
        #{<<"decode_budget_ms">> => 60000}
    ),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(60000, maps:get(decode_budget_ms, CtxOpts)).

%% `parameters.num_decode_budget_ms' (an /api/edit override) wins over
%% the loader value.
manifest_to_config_decode_budget_param_overrides_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    application:unset_env(barrel_inference_server, decode_budget_ms),
    Manifest0 = with_loader_keys(
        manifest(<<"sha256:0011">>, <<"q4_k_m">>, 4096, 4),
        #{<<"decode_budget_ms">> => 60000}
    ),
    Manifest = Manifest0#{<<"parameters">> => #{<<"num_decode_budget_ms">> => 5000}},
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(5000, maps:get(decode_budget_ms, CtxOpts)).

%% No manifest keys: fall back to the global `decode_budget_ms' app env.
manifest_to_config_decode_budget_app_env_fallback_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    application:set_env(barrel_inference_server, decode_budget_ms, 12000),
    Manifest = manifest(<<"sha256:0012">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    application:unset_env(barrel_inference_server, decode_budget_ms),
    ?assertEqual(12000, maps:get(decode_budget_ms, CtxOpts)).

%% Nothing set anywhere: the key is omitted so the engine keeps its
%% own default. Zero is a valid value (disables the budget) and is kept.
manifest_to_config_decode_budget_absent_and_zero_test() ->
    application:set_env(barrel_inference_server, max_context_size, 4096),
    application:unset_env(barrel_inference_server, decode_budget_ms),
    Manifest = manifest(<<"sha256:0013">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertNot(maps:is_key(decode_budget_ms, maps:get(context_opts, Config))),
    ManifestZero = with_loader_keys(Manifest, #{<<"decode_budget_ms">> => 0}),
    ConfigZero = barrel_inference_server_loader:manifest_to_config(ManifestZero),
    ?assertEqual(0, maps:get(decode_budget_ms, maps:get(context_opts, ConfigZero))).

with_loader_keys(Manifest, Extra) ->
    Loader = maps:get(<<"loader">>, Manifest, #{}),
    Manifest#{<<"loader">> => maps:merge(Loader, Extra)}.

%% Without an explicit `loader.n_batch', the loader picks a default
%% from the manifest's `parameter_size'. Larger models get a smaller
%% n_batch to keep the compute buffer in check.
manifest_to_config_auto_n_batch_from_parameter_size_test_() ->
    application:set_env(barrel_inference_server, max_context_size, 8192),
    [
        {"7B  -> 2048", batch_for_size_assert(<<"7B">>, 2048)},
        {"0.5B -> 2048", batch_for_size_assert(<<"0.5B">>, 2048)},
        {"13B -> 2048", batch_for_size_assert(<<"13B">>, 2048)},
        {"30B -> 1024", batch_for_size_assert(<<"30B">>, 1024)},
        {"32B -> 1024", batch_for_size_assert(<<"32B">>, 1024)},
        {"70B -> 512", batch_for_size_assert(<<"70B">>, 512)},
        {"405B -> 512", batch_for_size_assert(<<"405B">>, 512)},
        {"unknown -> 2048", batch_for_size_assert(undefined, 2048)},
        {"garbage -> 2048", batch_for_size_assert(<<"MoE-A3B">>, 2048)}
    ].

batch_for_size_assert(Size, Expected) ->
    fun() ->
        Manifest = manifest_with_param_size(Size),
        Config = barrel_inference_server_loader:manifest_to_config(Manifest),
        CtxOpts = maps:get(context_opts, Config),
        ?assertEqual(Expected, maps:get(n_batch, CtxOpts))
    end.

manifest_with_param_size(undefined) ->
    manifest(<<"sha256:0003">>, <<"q4_k_m">>, 4096, 4);
manifest_with_param_size(Size) ->
    (manifest(<<"sha256:0003">>, <<"q4_k_m">>, 4096, 4))#{
        <<"parameter_size">> => Size
    }.

%% Explicit `loader.n_batch' wins over the parameter-size heuristic.
manifest_to_config_explicit_n_batch_overrides_size_default_test() ->
    application:set_env(barrel_inference_server, max_context_size, 8192),
    Manifest = (manifest(<<"sha256:0004">>, <<"q4_k_m">>, 4096, 4))#{
        <<"parameter_size">> => <<"70B">>,
        <<"loader">> => #{<<"n_batch">> => 4096, <<"quant_bits">> => 4}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(4096, maps:get(n_batch, CtxOpts)).

%% `parameters.num_batch' (set via /api/edit) wins over both
%% `loader.n_batch' and the parameter_size heuristic. Mirrors how
%% Ollama's `PARAMETER num_X' overrides loader-derived values for
%% num_ctx today.
manifest_to_config_parameters_num_batch_overrides_loader_test() ->
    application:set_env(barrel_inference_server, max_context_size, 8192),
    Manifest = (manifest(<<"sha256:0010">>, <<"q4_k_m">>, 4096, 4))#{
        <<"parameter_size">> => <<"7B">>,
        <<"loader">> => #{<<"n_batch">> => 1024, <<"quant_bits">> => 4},
        <<"parameters">> => #{<<"num_batch">> => 256}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(256, maps:get(n_batch, CtxOpts)).

%% `parameters.num_seq_max' (set via /api/edit) wins over
%% `loader.n_seq_max'.
manifest_to_config_parameters_num_seq_max_overrides_loader_test() ->
    application:set_env(barrel_inference_server, max_context_size, 8192),
    Manifest = (manifest(<<"sha256:0011">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"n_seq_max">> => 4, <<"quant_bits">> => 4},
        <<"parameters">> => #{<<"num_seq_max">> => 2}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(2, maps:get(n_seq_max, CtxOpts)).

manifest_to_config_propagates_loader_overrides_test() ->
    application:set_env(barrel_inference_server, max_context_size, 8192),
    Manifest = (manifest(<<"sha256:0002">>, <<"q4_k_m">>, 8192, 4))#{
        <<"loader">> => #{
            <<"n_ctx">> => 8192,
            <<"n_batch">> => 256,
            <<"n_gpu_layers">> => 33,
            <<"quant_bits">> => 4
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(256, maps:get(n_batch, maps:get(context_opts, Config))),
    ?assertEqual(33, maps:get(n_gpu_layers, maps:get(model_opts, Config))).

%% Regression for the Metal-offload bug: a manifest with the default
%% `n_gpu_layers: 0` placeholder must NOT force CPU inference. Drop
%% the key from model_opts entirely so llama.cpp keeps its own
%% platform default (offload-all on GPU builds).
manifest_to_config_drops_zero_n_gpu_layers_test() ->
    Manifest = (manifest(<<"sha256:0003">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{
            <<"n_ctx">> => 4096,
            <<"n_batch">> => 512,
            <<"n_gpu_layers">> => 0,
            <<"quant_bits">> => 4
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ModelOpts = maps:get(model_opts, Config),
    ?assertNot(maps:is_key(n_gpu_layers, ModelOpts)).

%% Modelfile PARAMETER overrides manifest's loader value.
manifest_to_config_param_overrides_loader_for_n_gpu_layers_test() ->
    Manifest = (manifest(<<"sha256:0004">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"n_gpu_layers">> => 0, <<"quant_bits">> => 4},
        <<"parameters">> => #{<<"n_gpu_layers">> => 99}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(99, maps:get(n_gpu_layers, maps:get(model_opts, Config))).

%% barrel_inference 0.5.0 tool_call_markers wire from manifest -> load_model/2.
manifest_to_config_propagates_tool_call_markers_test() ->
    Manifest = (manifest(<<"sha256:0005">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{
            <<"quant_bits">> => 4,
            <<"tool_call_markers">> => #{
                <<"start">> => <<"<tool_call>">>,
                <<"end">> => <<"</tool_call>">>
            }
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(
        #{start => <<"<tool_call>">>, 'end' => <<"</tool_call>">>},
        maps:get(tool_call_markers, Config)
    ).

manifest_to_config_propagates_tool_call_payload_markers_test() ->
    Manifest = (manifest(<<"sha256:0006">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{
            <<"quant_bits">> => 4,
            <<"tool_call_markers">> => #{
                <<"start">> => <<"<tool_call>">>,
                <<"end">> => <<"</tool_call>">>,
                <<"payload_start">> => <<"<arg>">>,
                <<"payload_end">> => <<"</arg>">>
            }
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(
        #{
            start => <<"<tool_call>">>,
            'end' => <<"</tool_call>">>,
            payload_start => <<"<arg>">>,
            payload_end => <<"</arg>">>
        },
        maps:get(tool_call_markers, Config)
    ).

manifest_to_config_omits_tool_call_markers_when_absent_test() ->
    Manifest = manifest(<<"sha256:0007">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertNot(maps:is_key(tool_call_markers, Config)).

manifest_to_config_ignores_malformed_tool_call_markers_test() ->
    Manifest = (manifest(<<"sha256:0008">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{
            <<"quant_bits">> => 4,
            <<"tool_call_markers">> => #{<<"start">> => <<>>, <<"end">> => <<"</x>">>}
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertNot(maps:is_key(tool_call_markers, Config)).

%% Manifest's `loader.n_seq_max` becomes `context_opts.n_seq_max'.
%% Required for sticky-seq + continue/3 to admit more than one
%% session concurrently against the same model.
manifest_to_config_propagates_n_seq_max_test() ->
    Manifest = (manifest(<<"sha256:0009">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{
            <<"quant_bits">> => 4,
            <<"n_ctx">> => 4096,
            <<"n_seq_max">> => 4
        }
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(4, maps:get(n_seq_max, CtxOpts)).

manifest_to_config_defaults_n_seq_max_when_absent_test() ->
    %% A manifest that omits n_seq_max now resolves to the shared default
    %% (4), not the engine's deadlock-prone 1; the same resolver drives
    %% admission concurrency so the two layers stay coupled.
    Manifest = manifest(<<"sha256:000a">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(4, maps:get(n_seq_max, CtxOpts)).

manifest_to_config_ignores_zero_n_seq_max_test() ->
    %% `0` and negatives are invalid and collapse to the default (4).
    Manifest = (manifest(<<"sha256:000b">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"quant_bits">> => 4, <<"n_seq_max">> => 0}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(4, maps:get(n_seq_max, CtxOpts)).

%% `loader.embeddings = true` opens the context in embeddings mode so
%% barrel_inference:embed/2 returns vectors (set at pull for embedding GGUFs).
manifest_to_config_propagates_embeddings_test() ->
    Manifest = (manifest(<<"sha256:000c">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"quant_bits">> => 4, <<"embeddings">> => true}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    ?assertEqual(true, maps:get(embeddings, CtxOpts)).

manifest_to_config_omits_embeddings_when_absent_test() ->
    Manifest = manifest(<<"sha256:000d">>, <<"q4_k_m">>, 4096, 4),
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertNot(maps:is_key(embeddings, maps:get(context_opts, Config))).

%% `parameters.embeddings` (an /api/edit override) wins over the loader.
manifest_to_config_parameters_embeddings_overrides_test() ->
    Manifest = (manifest(<<"sha256:000e">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"quant_bits">> => 4},
        <<"parameters">> => #{<<"embeddings">> => true}
    },
    Config = barrel_inference_server_loader:manifest_to_config(Manifest),
    ?assertEqual(true, maps:get(embeddings, maps:get(context_opts, Config))).

%% =============================================================================
%% default_opts/1
%% =============================================================================

default_opts_returns_not_found_when_no_manifest_test() ->
    {ok, Cwd, OldEnv} = with_isolated_cache(),
    try
        ?assertEqual({error, not_found}, barrel_inference_server_loader:default_opts(<<"unknown">>))
    after
        restore_env(OldEnv),
        cleanup(Cwd)
    end.

default_opts_reads_existing_manifest_test() ->
    {ok, Cwd, OldEnv} = with_isolated_cache(),
    application:set_env(barrel_inference_server, max_context_size, 16384),
    try
        Manifest = manifest(<<"sha256:0011">>, <<"q4_k_m">>, 8192, 4),
        ok = write_manifest(Cwd, <<"my-model">>, <<"latest">>, Manifest),
        {ok, Config} = barrel_inference_server_loader:default_opts(<<"my-model">>),
        ?assertEqual(8192, maps:get(context_size, Config)),
        ?assertEqual(q4_k_m, maps:get(quant_type, Config))
    after
        restore_env(OldEnv),
        cleanup(Cwd)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

manifest(Digest, Quant, Ctx, Bits) ->
    Hex = strip_sha256(Digest),
    Path = list_to_binary("/blobs/sha256-" ++ binary_to_list(Hex) ++ ".gguf"),
    #{
        <<"name">> => <<"my-model">>,
        <<"tag">> => <<"latest">>,
        <<"spec">> => <<"file:///x.gguf">>,
        <<"digest">> => Digest,
        <<"blob_path">> => Path,
        <<"size_bytes">> => 1234,
        <<"format">> => <<"gguf">>,
        <<"quantization">> => Quant,
        <<"context_size">> => Ctx,
        <<"loader">> => #{<<"quant_bits">> => Bits, <<"n_ctx">> => Ctx}
    }.

strip_sha256(<<"sha256:", Rest/binary>>) -> Rest;
strip_sha256(B) -> B.

write_manifest(Cache, Name, Tag, Manifest) ->
    barrel_inference_server_models_store:write(Cache, Manifest#{
        <<"name">> => Name,
        <<"tag">> => Tag
    }).

with_isolated_cache() ->
    Cwd = make_tmp_dir(),
    OldEnv = application:get_env(barrel_inference_server, model_cache_dir),
    application:set_env(barrel_inference_server, model_cache_dir, Cwd),
    {ok, Cwd, OldEnv}.

restore_env(undefined) ->
    application:unset_env(barrel_inference_server, model_cache_dir);
restore_env({ok, V}) ->
    application:set_env(barrel_inference_server, model_cache_dir, V).

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "barrel_inference_server_loader_tests_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

cleanup(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.
