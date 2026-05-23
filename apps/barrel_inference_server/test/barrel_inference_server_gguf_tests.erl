%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_gguf_tests).

-include_lib("eunit/include/eunit.hrl").

%% GGUF value type tags.
-define(T_UINT8, 0).
-define(T_INT8, 1).
-define(T_UINT16, 2).
-define(T_INT16, 3).
-define(T_UINT32, 4).
-define(T_INT32, 5).
-define(T_FLOAT32, 6).
-define(T_BOOL, 7).
-define(T_STRING, 8).
-define(T_ARRAY, 9).
-define(T_UINT64, 10).
-define(T_FLOAT64, 12).

%% =============================================================================
%% Tests
%% =============================================================================

read_metadata_mixed_types_test() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"llama">>},
        {<<"llama.context_length">>, ?T_UINT32, 4096},
        {<<"llama.embedding_length">>, ?T_UINT32, 4096},
        {<<"general.file_type">>, ?T_UINT32, 15},
        {<<"general.size_label">>, ?T_STRING, <<"7B">>},
        {<<"general.use_eos">>, ?T_BOOL, true},
        {<<"general.temperature">>, ?T_FLOAT32, 0.8},
        {<<"general.byte_field">>, ?T_UINT8, 7},
        {<<"general.signed_field">>, ?T_INT8, -3},
        {<<"general.big_int">>, ?T_UINT64, 1234567890123},
        {<<"tokenizer.chat_template">>, ?T_STRING,
            <<"{% for message in messages %}{{ message.content }}{% endfor %}">>},
        {<<"tokenizer.ggml.tokens">>, ?T_ARRAY, {?T_STRING, [<<"a">>, <<"bb">>, <<"ccc">>]}}
    ],
    {ok, M} = with_synthetic_gguf(3, KVs, fun barrel_inference_server_gguf:read_metadata/1),
    ?assertEqual(<<"llama">>, maps:get(<<"general.architecture">>, M)),
    ?assertEqual(4096, maps:get(<<"llama.context_length">>, M)),
    ?assertEqual(4096, maps:get(<<"llama.embedding_length">>, M)),
    ?assertEqual(15, maps:get(<<"general.file_type">>, M)),
    ?assertEqual(<<"7B">>, maps:get(<<"general.size_label">>, M)),
    ?assertEqual(true, maps:get(<<"general.use_eos">>, M)),
    ?assert(abs(maps:get(<<"general.temperature">>, M) - 0.8) < 1.0e-6),
    ?assertEqual(7, maps:get(<<"general.byte_field">>, M)),
    ?assertEqual(-3, maps:get(<<"general.signed_field">>, M)),
    ?assertEqual(1234567890123, maps:get(<<"general.big_int">>, M)),
    ?assert(byte_size(maps:get(<<"tokenizer.chat_template">>, M)) > 0),
    ?assertEqual([<<"a">>, <<"bb">>, <<"ccc">>], maps:get(<<"tokenizer.ggml.tokens">>, M)).

bad_magic_test() ->
    {Path, _Bin} = write_tmp(<<"NOPE", (gguf_tail([]))/binary>>),
    try
        ?assertEqual({error, bad_magic}, barrel_inference_server_gguf:read_metadata(Path))
    after
        file:delete(Path)
    end.

bad_version_test() ->
    Bin = <<"GGUF", 99:32/little, 0:64/little, 0:64/little>>,
    {Path, _} = write_tmp(Bin),
    try
        ?assertEqual({error, {bad_version, 99}}, barrel_inference_server_gguf:read_metadata(Path))
    after
        file:delete(Path)
    end.

truncated_header_test() ->
    {Path, _} = write_tmp(<<"GGUF", 3:32/little, 0:64/little>>),
    try
        ?assertEqual({error, truncated}, barrel_inference_server_gguf:read_metadata(Path))
    after
        file:delete(Path)
    end.

truncated_value_test() ->
    %% Header announces 1 KV pair but body is cut after the key.
    KeyName = <<"truncated.key">>,
    Bin = <<
        "GGUF",
        3:32/little,
        0:64/little,
        1:64/little,
        (byte_size(KeyName)):64/little,
        KeyName/binary
    >>,
    {Path, _} = write_tmp(Bin),
    try
        ?assertEqual({error, truncated}, barrel_inference_server_gguf:read_metadata(Path))
    after
        file:delete(Path)
    end.

file_open_failure_test() ->
    ?assertMatch(
        {error, _},
        barrel_inference_server_gguf:read_metadata("/this/file/should/not/exist.gguf")
    ).

extractors_test() ->
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"qwen2">>},
        {<<"qwen2.context_length">>, ?T_UINT32, 32768},
        {<<"qwen2.embedding_length">>, ?T_UINT32, 4096},
        {<<"general.file_type">>, ?T_UINT32, 17},
        {<<"general.size_label">>, ?T_STRING, <<"7B">>},
        {<<"tokenizer.chat_template">>, ?T_STRING, <<"chat-template-body">>},
        {<<"tokenizer.ggml.model">>, ?T_STRING, <<"gpt2">>}
    ],
    {ok, M} = with_synthetic_gguf(3, KVs, fun barrel_inference_server_gguf:read_metadata/1),
    ?assertEqual(<<"qwen2">>, barrel_inference_server_gguf:architecture(M)),
    ?assertEqual(<<"qwen">>, barrel_inference_server_gguf:family(M)),
    ?assertEqual(<<"7B">>, barrel_inference_server_gguf:parameter_size_label(M)),
    ?assertEqual(32768, barrel_inference_server_gguf:context_length(M)),
    ?assertEqual(4096, barrel_inference_server_gguf:embedding_length(M)),
    ?assertEqual(<<"q5_k_m">>, barrel_inference_server_gguf:quantization(M)),
    ?assertEqual(<<"chat-template-body">>, barrel_inference_server_gguf:chat_template(M)),
    ?assertEqual(<<"gpt2">>, barrel_inference_server_gguf:tokenizer_model(M)).

family_unknown_arch_passes_through_test() ->
    KVs = [{<<"general.architecture">>, ?T_STRING, <<"weird-new-arch">>}],
    {ok, M} = with_synthetic_gguf(3, KVs, fun barrel_inference_server_gguf:read_metadata/1),
    ?assertEqual(<<"weird-new-arch">>, barrel_inference_server_gguf:family(M)).

family_phi_mappings_test() ->
    {ok, M3} = with_synthetic_gguf(
        3,
        [{<<"general.architecture">>, ?T_STRING, <<"phi3">>}],
        fun barrel_inference_server_gguf:read_metadata/1
    ),
    {ok, M4} = with_synthetic_gguf(
        3,
        [{<<"general.architecture">>, ?T_STRING, <<"phi4">>}],
        fun barrel_inference_server_gguf:read_metadata/1
    ),
    ?assertEqual(<<"phi">>, barrel_inference_server_gguf:family(M3)),
    ?assertEqual(<<"phi">>, barrel_inference_server_gguf:family(M4)).

quantization_mapping_test() ->
    Cases = [
        {0, <<"f32">>},
        {1, <<"f16">>},
        {2, <<"q4_0">>},
        {7, <<"q8_0">>},
        {15, <<"q4_k_m">>},
        {17, <<"q5_k_m">>},
        {32, <<"bf16">>},
        {99, <<"unknown">>}
    ],
    [
        begin
            KVs = [{<<"general.file_type">>, ?T_UINT32, FType}],
            {ok, M} = with_synthetic_gguf(3, KVs, fun barrel_inference_server_gguf:read_metadata/1),
            ?assertEqual(Label, barrel_inference_server_gguf:quantization(M))
        end
     || {FType, Label} <- Cases
    ].

extractor_undefined_when_missing_test() ->
    {ok, M} = with_synthetic_gguf(3, [], fun barrel_inference_server_gguf:read_metadata/1),
    ?assertEqual(undefined, barrel_inference_server_gguf:architecture(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:family(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:parameter_size_label(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:context_length(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:embedding_length(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:quantization(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:chat_template(M)),
    ?assertEqual(undefined, barrel_inference_server_gguf:tokenizer_model(M)).

reads_past_chunk_boundary_test() ->
    %% Force the parser to refill its buffer mid-parse by stuffing a
    %% string longer than CHUNK_BYTES (64 KiB).
    Big = binary:copy(<<"x">>, 70 * 1024),
    KVs = [
        {<<"general.architecture">>, ?T_STRING, <<"llama">>},
        {<<"general.big_blob">>, ?T_STRING, Big}
    ],
    {ok, M} = with_synthetic_gguf(3, KVs, fun barrel_inference_server_gguf:read_metadata/1),
    ?assertEqual(byte_size(Big), byte_size(maps:get(<<"general.big_blob">>, M))).

%% =============================================================================
%% Synthetic GGUF helpers
%% =============================================================================

with_synthetic_gguf(Version, KVs, Fun) ->
    Bin = build_gguf(Version, KVs),
    {Path, _} = write_tmp(Bin),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.

build_gguf(Version, KVs) ->
    Body = encode_kvs(KVs),
    <<"GGUF", Version:32/little, 0:64/little, (length(KVs)):64/little, Body/binary>>.

%% Header for a zero-tensor zero-kv GGUF v3 file.
gguf_tail(_KVs) ->
    <<3:32/little, 0:64/little, 0:64/little>>.

encode_kvs(KVs) ->
    iolist_to_binary([encode_kv(K, T, V) || {K, T, V} <- KVs]).

encode_kv(Key, Type, Value) ->
    <<(encode_string(Key))/binary, Type:32/little, (encode_value(Type, Value))/binary>>.

encode_value(?T_UINT8, V) -> <<V:8/little-unsigned>>;
encode_value(?T_INT8, V) -> <<V:8/little-signed>>;
encode_value(?T_UINT16, V) -> <<V:16/little-unsigned>>;
encode_value(?T_INT16, V) -> <<V:16/little-signed>>;
encode_value(?T_UINT32, V) -> <<V:32/little-unsigned>>;
encode_value(?T_INT32, V) -> <<V:32/little-signed>>;
encode_value(?T_FLOAT32, V) -> <<V:32/little-float>>;
encode_value(?T_BOOL, true) -> <<1:8>>;
encode_value(?T_BOOL, false) -> <<0:8>>;
encode_value(?T_STRING, V) -> encode_string(V);
encode_value(?T_UINT64, V) -> <<V:64/little-unsigned>>;
encode_value(?T_FLOAT64, V) -> <<V:64/little-float>>;
encode_value(?T_ARRAY, {InnerType, Items}) -> encode_array(InnerType, Items).

encode_string(Bin) ->
    <<(byte_size(Bin)):64/little-unsigned, Bin/binary>>.

encode_array(InnerType, Items) ->
    Body = iolist_to_binary([encode_value(InnerType, I) || I <- Items]),
    <<InnerType:32/little, (length(Items)):64/little-unsigned, Body/binary>>.

write_tmp(Bin) ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Path = filename:join(
        Base,
        "barrel_inference_server_gguf_" ++ integer_to_list(erlang:unique_integer([positive])) ++
            ".gguf"
    ),
    ok = file:write_file(Path, Bin),
    {Path, Bin}.
