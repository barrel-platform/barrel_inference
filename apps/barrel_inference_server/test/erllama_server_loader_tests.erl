%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_loader_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% manifest_to_config/1
%% =============================================================================

manifest_to_config_basic_test() ->
    application:set_env(erllama_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:6a01">>, <<"q4_k_m">>, 4096, 4),
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual("/blobs/sha256-6a01.gguf", maps:get(model_path, Config)),
    ?assertEqual(q4_k_m, maps:get(quant_type, Config)),
    ?assertEqual(4, maps:get(quant_bits, Config)),
    ?assertEqual(4096, maps:get(context_size, Config)),
    ?assert(is_binary(maps:get(fingerprint, Config))).

manifest_to_config_caps_context_size_test() ->
    application:set_env(erllama_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:6a01">>, <<"q4_k_m">>, 131072, 4),
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual(4096, maps:get(context_size, Config)).

manifest_to_config_defaults_when_missing_test() ->
    Manifest = #{
        <<"name">> => <<"x">>,
        <<"tag">> => <<"latest">>,
        <<"blob_path">> => <<"/blob.gguf">>
    },
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual("/blob.gguf", maps:get(model_path, Config)),
    ?assertEqual(f16, maps:get(quant_type, Config)),
    ?assertEqual(4, maps:get(quant_bits, Config)),
    ?assertEqual(4096, maps:get(context_size, Config)).

manifest_to_config_fingerprint_padding_test() ->
    %% A short hex digest decodes to <32 bytes; the fallback zero
    %% fingerprint kicks in.
    Manifest = manifest(<<"sha256:abcd">>, <<"q4_k_m">>, 4096, 4),
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual(32, byte_size(maps:get(fingerprint, Config))).

%% erllama_model_llama reads context_opts/model_opts and forwards them
%% to the NIF. Without n_ctx wired through, llama.cpp falls back to
%% 512 and segfaults on any input larger than that. Regression for
%% the segfault hit while pointing Claude Code at the daemon.
manifest_to_config_passes_n_ctx_to_context_opts_test() ->
    application:set_env(erllama_server, max_context_size, 4096),
    Manifest = manifest(<<"sha256:0001">>, <<"q4_k_m">>, 8192, 4),
    Config = erllama_server_loader:manifest_to_config(Manifest),
    CtxOpts = maps:get(context_opts, Config),
    %% Capped at max_context_size.
    ?assertEqual(4096, maps:get(n_ctx, CtxOpts)),
    %% n_batch falls through from the manifest's loader.n_batch when
    %% set; defaults to 512 otherwise.
    ?assert(is_integer(maps:get(n_batch, CtxOpts))).

manifest_to_config_propagates_loader_overrides_test() ->
    application:set_env(erllama_server, max_context_size, 8192),
    Manifest = (manifest(<<"sha256:0002">>, <<"q4_k_m">>, 8192, 4))#{
        <<"loader">> => #{
            <<"n_ctx">> => 8192,
            <<"n_batch">> => 256,
            <<"n_gpu_layers">> => 33,
            <<"quant_bits">> => 4
        }
    },
    Config = erllama_server_loader:manifest_to_config(Manifest),
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
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ModelOpts = maps:get(model_opts, Config),
    ?assertNot(maps:is_key(n_gpu_layers, ModelOpts)).

%% Modelfile PARAMETER overrides manifest's loader value.
manifest_to_config_param_overrides_loader_for_n_gpu_layers_test() ->
    Manifest = (manifest(<<"sha256:0004">>, <<"q4_k_m">>, 4096, 4))#{
        <<"loader">> => #{<<"n_gpu_layers">> => 0, <<"quant_bits">> => 4},
        <<"parameters">> => #{<<"n_gpu_layers">> => 99}
    },
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual(99, maps:get(n_gpu_layers, maps:get(model_opts, Config))).

%% =============================================================================
%% default_opts/1
%% =============================================================================

default_opts_returns_not_found_when_no_manifest_test() ->
    {ok, Cwd, OldEnv} = with_isolated_cache(),
    try
        ?assertEqual({error, not_found}, erllama_server_loader:default_opts(<<"unknown">>))
    after
        restore_env(OldEnv),
        cleanup(Cwd)
    end.

default_opts_reads_existing_manifest_test() ->
    {ok, Cwd, OldEnv} = with_isolated_cache(),
    application:set_env(erllama_server, max_context_size, 16384),
    try
        Manifest = manifest(<<"sha256:0011">>, <<"q4_k_m">>, 8192, 4),
        ok = write_manifest(Cwd, <<"my-model">>, <<"latest">>, Manifest),
        {ok, Config} = erllama_server_loader:default_opts(<<"my-model">>),
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
    erllama_server_models_store:write(Cache, Manifest#{
        <<"name">> => Name,
        <<"tag">> => Tag
    }).

with_isolated_cache() ->
    Cwd = make_tmp_dir(),
    OldEnv = application:get_env(erllama_server, model_cache_dir),
    application:set_env(erllama_server, model_cache_dir, Cwd),
    {ok, Cwd, OldEnv}.

restore_env(undefined) ->
    application:unset_env(erllama_server, model_cache_dir);
restore_env({ok, V}) ->
    application:set_env(erllama_server, model_cache_dir, V).

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_loader_tests_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

cleanup(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.
