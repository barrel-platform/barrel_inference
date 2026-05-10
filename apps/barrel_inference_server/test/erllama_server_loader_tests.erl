%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_loader_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% manifest_to_config/1
%% =============================================================================

manifest_to_config_basic_test() ->
    Manifest = manifest(<<"sha256:6a01">>, <<"q4_k_m">>, 4096, 4),
    Config = erllama_server_loader:manifest_to_config(Manifest),
    ?assertEqual("/blobs/sha256-6a01.gguf", maps:get(model_path, Config)),
    ?assertEqual(q4_k_m, maps:get(quant_type, Config)),
    ?assertEqual(4, maps:get(quant_bits, Config)),
    ?assertEqual(4096, maps:get(context_size, Config)),
    ?assert(is_binary(maps:get(fingerprint, Config))).

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
