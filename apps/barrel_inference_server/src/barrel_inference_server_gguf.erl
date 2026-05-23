%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_gguf).
-moduledoc """
Pure Erlang reader for GGUF v3 metadata.

The on-disk format is documented at
`https://github.com/ggml-org/ggml/blob/master/docs/gguf.md`. We read
only the header and the metadata KV section; tensor data is not
touched (it lives past `tensor_count` tensor info entries which we
do not parse).

Public API:

```
read_metadata(Path) -> {ok, gguf_metadata()} | {error, term()}
```

A handful of named extractors live next to the raw map for the
fields the registry cares about: architecture, family,
parameter_size_label, context_length, embedding_length,
quantization, chat_template, tokenizer_model.
""".

-export([
    read_metadata/1,
    architecture/1,
    family/1,
    parameter_size_label/1,
    context_length/1,
    embedding_length/1,
    quantization/1,
    chat_template/1,
    tokenizer_model/1
]).

-export_type([gguf_metadata/0, gguf_value/0]).

-type gguf_value() ::
    integer()
    | float()
    | boolean()
    | binary()
    | [gguf_value()].
-type gguf_metadata() :: #{binary() => gguf_value()}.

-define(GGUF_MAGIC, <<"GGUF">>).
-define(SUPPORTED_VERSIONS, [3]).
-define(CHUNK_BYTES, 65536).

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
-define(T_INT64, 11).
-define(T_FLOAT64, 12).

-record(rd, {
    io :: file:io_device(),
    buf :: binary(),
    eof = false :: boolean()
}).

%% =============================================================================
%% Public API
%% =============================================================================

-spec read_metadata(file:name_all()) -> {ok, gguf_metadata()} | {error, term()}.
read_metadata(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, IO} ->
            try
                do_read_metadata(IO)
            after
                _ = file:close(IO)
            end;
        {error, _} = E ->
            E
    end.

-spec architecture(gguf_metadata()) -> binary() | undefined.
architecture(M) ->
    case maps:get(<<"general.architecture">>, M, undefined) of
        Bin when is_binary(Bin) -> Bin;
        _ -> undefined
    end.

-spec family(gguf_metadata()) -> binary() | undefined.
family(M) ->
    case architecture(M) of
        undefined -> undefined;
        Arch -> family_of(Arch)
    end.

-spec parameter_size_label(gguf_metadata()) -> binary() | undefined.
parameter_size_label(M) ->
    case maps:get(<<"general.size_label">>, M, undefined) of
        Bin when is_binary(Bin), Bin =/= <<>> -> Bin;
        _ -> undefined
    end.

-spec context_length(gguf_metadata()) -> pos_integer() | undefined.
context_length(M) ->
    arch_int(<<".context_length">>, M).

-spec embedding_length(gguf_metadata()) -> pos_integer() | undefined.
embedding_length(M) ->
    arch_int(<<".embedding_length">>, M).

-spec quantization(gguf_metadata()) -> binary() | undefined.
quantization(M) ->
    case maps:get(<<"general.file_type">>, M, undefined) of
        N when is_integer(N) -> ftype_label(N);
        _ -> undefined
    end.

-spec chat_template(gguf_metadata()) -> binary() | undefined.
chat_template(M) ->
    case maps:get(<<"tokenizer.chat_template">>, M, undefined) of
        Bin when is_binary(Bin), Bin =/= <<>> -> Bin;
        _ -> undefined
    end.

-spec tokenizer_model(gguf_metadata()) -> binary() | undefined.
tokenizer_model(M) ->
    case maps:get(<<"tokenizer.ggml.model">>, M, undefined) of
        Bin when is_binary(Bin), Bin =/= <<>> -> Bin;
        _ -> undefined
    end.

%% =============================================================================
%% Top-level read
%% =============================================================================

do_read_metadata(IO) ->
    R0 = #rd{io = IO, buf = <<>>},
    case fill(R0, 24) of
        {ok, R1} ->
            <<Magic:4/binary, Version:32/little, TensorCount:64/little, KvCount:64/little,
                Rest/binary>> = R1#rd.buf,
            case Magic of
                ?GGUF_MAGIC ->
                    case lists:member(Version, ?SUPPORTED_VERSIONS) of
                        true ->
                            R2 = R1#rd{buf = Rest},
                            parse_kvs(R2, KvCount, #{
                                <<"_tensor_count">> => TensorCount,
                                <<"_version">> => Version
                            });
                        false ->
                            {error, {bad_version, Version}}
                    end;
                _ ->
                    {error, bad_magic}
            end;
        {error, _} = E ->
            E
    end.

parse_kvs(_R, 0, Acc) ->
    {ok, maps:remove(<<"_tensor_count">>, maps:remove(<<"_version">>, Acc))};
parse_kvs(R, N, Acc) ->
    case parse_kv(R) of
        {ok, Key, Value, R1} -> parse_kvs(R1, N - 1, Acc#{Key => Value});
        {error, _} = E -> E
    end.

parse_kv(R) ->
    case read_string(R) of
        {ok, Key, R1} ->
            case fill(R1, 4) of
                {ok, R2} ->
                    <<Type:32/little, Rest/binary>> = R2#rd.buf,
                    R3 = R2#rd{buf = Rest},
                    case read_value(Type, R3) of
                        {ok, V, R4} -> {ok, Key, V, R4};
                        E -> E
                    end;
                E ->
                    E
            end;
        E ->
            E
    end.

%% =============================================================================
%% Value reader
%% =============================================================================

read_value(?T_UINT8, R) -> read_uint(1, R);
read_value(?T_INT8, R) -> read_int(1, R);
read_value(?T_UINT16, R) -> read_uint(2, R);
read_value(?T_INT16, R) -> read_int(2, R);
read_value(?T_UINT32, R) -> read_uint(4, R);
read_value(?T_INT32, R) -> read_int(4, R);
read_value(?T_FLOAT32, R) -> read_float(4, R);
read_value(?T_BOOL, R) -> read_bool(R);
read_value(?T_STRING, R) -> read_string(R);
read_value(?T_UINT64, R) -> read_uint(8, R);
read_value(?T_INT64, R) -> read_int(8, R);
read_value(?T_FLOAT64, R) -> read_float(8, R);
read_value(?T_ARRAY, R) -> read_array(R);
read_value(Other, _R) -> {error, {bad_value_type, Other}}.

read_uint(N, R) ->
    case fill(R, N) of
        {ok, R1} ->
            Bits = N * 8,
            <<V:Bits/little-unsigned, Rest/binary>> = R1#rd.buf,
            {ok, V, R1#rd{buf = Rest}};
        E ->
            E
    end.

read_int(N, R) ->
    case fill(R, N) of
        {ok, R1} ->
            Bits = N * 8,
            <<V:Bits/little-signed, Rest/binary>> = R1#rd.buf,
            {ok, V, R1#rd{buf = Rest}};
        E ->
            E
    end.

read_float(4, R) ->
    case fill(R, 4) of
        {ok, R1} ->
            <<V:32/little-float, Rest/binary>> = R1#rd.buf,
            {ok, V, R1#rd{buf = Rest}};
        E ->
            E
    end;
read_float(8, R) ->
    case fill(R, 8) of
        {ok, R1} ->
            <<V:64/little-float, Rest/binary>> = R1#rd.buf,
            {ok, V, R1#rd{buf = Rest}};
        E ->
            E
    end.

read_bool(R) ->
    case fill(R, 1) of
        {ok, R1} ->
            <<B:8, Rest/binary>> = R1#rd.buf,
            {ok, B =/= 0, R1#rd{buf = Rest}};
        E ->
            E
    end.

read_string(R) ->
    case fill(R, 8) of
        {ok, R1} ->
            <<Len:64/little-unsigned, Rest/binary>> = R1#rd.buf,
            R2 = R1#rd{buf = Rest},
            case fill(R2, Len) of
                {ok, R3} ->
                    <<S:Len/binary, Tail/binary>> = R3#rd.buf,
                    {ok, S, R3#rd{buf = Tail}};
                E ->
                    E
            end;
        E ->
            E
    end.

read_array(R) ->
    case fill(R, 12) of
        {ok, R1} ->
            <<Inner:32/little, Len:64/little-unsigned, Rest/binary>> = R1#rd.buf,
            read_array_items(Inner, Len, R1#rd{buf = Rest}, []);
        E ->
            E
    end.

read_array_items(_Inner, 0, R, Acc) ->
    {ok, lists:reverse(Acc), R};
read_array_items(Inner, N, R, Acc) ->
    case read_value(Inner, R) of
        {ok, V, R1} -> read_array_items(Inner, N - 1, R1, [V | Acc]);
        E -> E
    end.

%% =============================================================================
%% Buffered reader
%% =============================================================================

fill(#rd{buf = Buf} = R, N) when byte_size(Buf) >= N ->
    {ok, R};
fill(#rd{eof = true}, _N) ->
    {error, truncated};
fill(#rd{io = IO, buf = Buf} = R, N) ->
    Want = max(?CHUNK_BYTES, N - byte_size(Buf)),
    case file:read(IO, Want) of
        {ok, Data} ->
            fill(R#rd{buf = <<Buf/binary, Data/binary>>}, N);
        eof ->
            case byte_size(Buf) >= N of
                true -> {ok, R#rd{eof = true}};
                false -> {error, truncated}
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% Mappings: family + ftype
%% =============================================================================

%% Coarse family label keyed off `general.architecture`. Falls back
%% to the architecture string itself when unknown.
family_of(<<"llama">>) -> <<"llama">>;
family_of(<<"qwen">>) -> <<"qwen">>;
family_of(<<"qwen2">>) -> <<"qwen">>;
family_of(<<"qwen3">>) -> <<"qwen">>;
family_of(<<"qwen2vl">>) -> <<"qwen">>;
family_of(<<"phi">>) -> <<"phi">>;
family_of(<<"phi2">>) -> <<"phi">>;
family_of(<<"phi3">>) -> <<"phi">>;
family_of(<<"phi4">>) -> <<"phi">>;
family_of(<<"gemma">>) -> <<"gemma">>;
family_of(<<"gemma2">>) -> <<"gemma">>;
family_of(<<"gemma3">>) -> <<"gemma">>;
family_of(<<"mistral">>) -> <<"mistral">>;
family_of(<<"mixtral">>) -> <<"mistral">>;
family_of(<<"deepseek">>) -> <<"deepseek">>;
family_of(<<"deepseek2">>) -> <<"deepseek">>;
family_of(<<"baichuan">>) -> <<"baichuan">>;
family_of(<<"starcoder">>) -> <<"starcoder">>;
family_of(<<"starcoder2">>) -> <<"starcoder">>;
family_of(<<"falcon">>) -> <<"falcon">>;
family_of(<<"mpt">>) -> <<"mpt">>;
family_of(<<"bloom">>) -> <<"bloom">>;
family_of(<<"gpt2">>) -> <<"gpt2">>;
family_of(<<"gptneox">>) -> <<"gptneox">>;
family_of(<<"command-r">>) -> <<"command-r">>;
family_of(<<"olmo">>) -> <<"olmo">>;
family_of(<<"granite">>) -> <<"granite">>;
family_of(Other) when is_binary(Other) -> Other.

%% Mirror llama.cpp's `LLAMA_FTYPE_*` enum (lowercased). Unknown
%% values fall through to `unknown`.
ftype_label(0) -> <<"f32">>;
ftype_label(1) -> <<"f16">>;
ftype_label(2) -> <<"q4_0">>;
ftype_label(3) -> <<"q4_1">>;
ftype_label(7) -> <<"q8_0">>;
ftype_label(8) -> <<"q5_0">>;
ftype_label(9) -> <<"q5_1">>;
ftype_label(10) -> <<"q2_k">>;
ftype_label(11) -> <<"q3_k_s">>;
ftype_label(12) -> <<"q3_k_m">>;
ftype_label(13) -> <<"q3_k_l">>;
ftype_label(14) -> <<"q4_k_s">>;
ftype_label(15) -> <<"q4_k_m">>;
ftype_label(16) -> <<"q5_k_s">>;
ftype_label(17) -> <<"q5_k_m">>;
ftype_label(18) -> <<"q6_k">>;
ftype_label(19) -> <<"iq2_xxs">>;
ftype_label(20) -> <<"iq2_xs">>;
ftype_label(21) -> <<"q2_k_s">>;
ftype_label(22) -> <<"iq3_xs">>;
ftype_label(23) -> <<"iq3_xxs">>;
ftype_label(24) -> <<"iq1_s">>;
ftype_label(25) -> <<"iq4_nl">>;
ftype_label(26) -> <<"iq3_s">>;
ftype_label(27) -> <<"iq3_m">>;
ftype_label(28) -> <<"iq2_s">>;
ftype_label(29) -> <<"iq2_m">>;
ftype_label(30) -> <<"iq4_xs">>;
ftype_label(31) -> <<"iq1_m">>;
ftype_label(32) -> <<"bf16">>;
ftype_label(_) -> <<"unknown">>.

%% =============================================================================
%% Internal: <arch>.<suffix> field lookup
%% =============================================================================

arch_int(Suffix, M) ->
    case architecture(M) of
        undefined ->
            undefined;
        Arch ->
            Key = <<Arch/binary, Suffix/binary>>,
            case maps:get(Key, M, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> undefined
            end
    end.
