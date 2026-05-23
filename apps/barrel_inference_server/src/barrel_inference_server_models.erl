%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_models).
-moduledoc """
Ollama-style model registry.

Layered over `barrel_inference_server_fetch` (download + content-addressed
blob cache) and `barrel_inference_server_gguf` (metadata sniffing). Persists
one JSON manifest per `name:tag` under
`<cache_root>/manifests/<name>/<tag>.json`. The blob itself stays
in `<cache_root>/blobs/sha256-<hex>.gguf` and may be referenced by
multiple manifests (`copy/2`).

Public surface:

```
list/0                  -> [manifest()]
get/1, show/1           -> {ok, manifest()} | {error, not_found}
pull/1, pull/2          -> {ok, manifest()} | {error, term()}
delete/1                -> ok | {error, not_found}
copy/2                  -> ok | {error, term()}
resolve_spec/1          -> {Spec, Name, Tag} (used by CLI / API too)
```

`pull/1,2` accepts either a fetch spec (`hf://`, `ollama://`,
`https://`, `file://`) or a short Ollama-style name (`llama3`,
`llama3:8b`); the latter is rewritten to `ollama://library/<name>`.
Manifest fields are sniffed from the GGUF file once the blob is on
disk: `architecture`, `family`, `parameter_size`, `quantization`,
`context_size`, `embedding_length`, `chat_template` (raw).
""".

-export([
    list/0,
    get/1,
    show/1,
    pull/1,
    pull/2,
    edit/2,
    delete/1,
    copy/2,
    resolve_spec/1,
    persist_manifest/4,
    cache_root/0
]).

-export_type([manifest/0, name_or_tag/0, pull_opts/0]).

-type manifest() :: barrel_inference_server_models_store:manifest().
-type name_or_tag() :: binary() | string().
-type pull_opts() :: #{
    name => binary() | string(),
    tag => binary() | string(),
    progress => pid(),
    sha256 => binary(),
    timeout => pos_integer(),
    force => boolean(),
    modelfile_overrides => modelfile_overrides()
}.

-type modelfile_overrides() :: #{
    system => binary(),
    template => binary(),
    parameters => map()
}.

%% =============================================================================
%% Public API
%% =============================================================================

-spec list() -> [manifest()].
list() ->
    {ok, Root} = cache_root(),
    barrel_inference_server_models_store:list(Root).

-spec get(name_or_tag()) -> {ok, manifest()} | {error, not_found | term()}.
get(NameOrTag) ->
    {Name, Tag} = split_name_tag(NameOrTag),
    {ok, Root} = cache_root(),
    barrel_inference_server_models_store:read(Root, Name, Tag).

-spec show(name_or_tag()) -> {ok, manifest()} | {error, not_found | term()}.
show(NameOrTag) ->
    ?MODULE:get(NameOrTag).

-spec pull(name_or_tag()) -> {ok, manifest()} | {error, term()}.
pull(SpecOrName) ->
    pull(SpecOrName, #{}).

-spec pull(name_or_tag(), pull_opts()) -> {ok, manifest()} | {error, term()}.
pull(SpecOrName, Opts) when is_map(Opts) ->
    case resolve_spec(SpecOrName) of
        {ok, Spec, DefName, DefTag} ->
            Name = to_bin(maps:get(name, Opts, DefName)),
            Tag = to_bin(maps:get(tag, Opts, DefTag)),
            Overrides = maps:get(modelfile_overrides, Opts, #{}),
            FetchOpts = maps:without([name, tag, modelfile_overrides], Opts),
            do_pull(Spec, Name, Tag, FetchOpts, Overrides);
        {error, _} = E ->
            E
    end.

%% Merge `Overrides' (a flat map of `binary() => json_scalar()')
%% into the manifest's `parameters' sub-map and persist atomically.
%% Existing keys not mentioned in `Overrides' stay intact;
%% mentioned keys are overwritten. The loaded model (if any) keeps
%% running with its current context_opts; the new values take
%% effect on the next admit after the model unloads. See
%% `guides/clients.md' for the operator-facing flow.
-spec edit(name_or_tag(), map()) ->
    {ok, manifest()} | {error, not_found | bad_parameters | term()}.
edit(NameOrTag, Overrides) when is_map(Overrides) ->
    case validate_parameters(Overrides) of
        ok ->
            {Name, Tag} = split_name_tag(NameOrTag),
            {ok, Root} = cache_root(),
            case barrel_inference_server_models_store:read(Root, Name, Tag) of
                {ok, Manifest} ->
                    Existing = maps:get(<<"parameters">>, Manifest, #{}),
                    Merged = maps:merge(Existing, Overrides),
                    Updated = Manifest#{<<"parameters">> => Merged},
                    case barrel_inference_server_models_store:write(Root, Updated) of
                        ok -> {ok, Updated};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
edit(_, _) ->
    {error, bad_parameters}.

%% Reject lists, nested maps, atoms, anything that wouldn't
%% round-trip as a Modelfile PARAMETER value.
validate_parameters(Overrides) ->
    case maps:fold(fun validate_param/3, ok, Overrides) of
        ok -> ok;
        {error, _} = E -> E
    end.

validate_param(_, _, {error, _} = E) ->
    E;
validate_param(K, _, _) when not is_binary(K) -> {error, bad_parameters};
validate_param(_, V, ok) when is_integer(V); is_float(V); is_binary(V); is_boolean(V) ->
    ok;
validate_param(_, _, _) ->
    {error, bad_parameters}.

-spec delete(name_or_tag()) -> ok | {error, not_found | term()}.
delete(NameOrTag) ->
    {Name, Tag} = split_name_tag(NameOrTag),
    {ok, Root} = cache_root(),
    barrel_inference_server_models_store:delete(Root, Name, Tag).

-spec copy(name_or_tag(), name_or_tag()) -> ok | {error, term()}.
copy(Src, Dst) ->
    {SrcName, SrcTag} = split_name_tag(Src),
    {DstName, DstTag} = split_name_tag(Dst),
    {ok, Root} = cache_root(),
    barrel_inference_server_models_store:copy(Root, SrcName, SrcTag, DstName, DstTag).

%% Resolves a user-supplied spec or short name into:
%%   {ok, FetchSpec, DefaultName, DefaultTag}
%% A bare name like "llama3" or "llama3:8b" is rewritten to
%% `ollama://library/<name>:<tag>`.
-spec resolve_spec(name_or_tag()) ->
    {ok, binary(), binary(), binary()} | {error, term()}.
resolve_spec(SpecOrName) ->
    Bin = to_bin(SpecOrName),
    case barrel_inference_server_fetch_resolvers:parse(Bin) of
        {ok, Parsed} ->
            {DefName, DefTag} = derive_name_tag(Parsed),
            {ok, Bin, DefName, DefTag};
        {error, _} ->
            wrap_short_ollama(Bin)
    end.

-spec cache_root() -> {ok, file:filename_all()}.
cache_root() ->
    barrel_inference_server_fetch:cache_root().

%% =============================================================================
%% Internal: name/tag derivation
%% =============================================================================

derive_name_tag({ollama, <<"library">>, Name, Tag}) ->
    {Name, Tag};
derive_name_tag({ollama, Library, Name, Tag}) ->
    {<<Library/binary, "/", Name/binary>>, Tag};
derive_name_tag({hf, Org, Repo, _Path, Rev}) ->
    {<<Org/binary, "/", Repo/binary>>, Rev};
derive_name_tag({http, URL}) ->
    {url_basename(URL), <<"latest">>};
derive_name_tag({file, Abs}) ->
    {strip_ext(to_bin(filename:basename(Abs))), <<"latest">>}.

wrap_short_ollama(Bin) ->
    {Name, Tag} = split_name_tag(Bin),
    case is_valid_short(Name) of
        true ->
            Spec = <<"ollama://library/", Name/binary, ":", Tag/binary>>,
            {ok, Spec, Name, Tag};
        false ->
            {error, {unsupported_spec, Bin}}
    end.

is_valid_short(<<>>) -> false;
is_valid_short(Name) -> not has_scheme(Name).

has_scheme(Bin) ->
    binary:match(Bin, <<"://">>) =/= nomatch.

split_name_tag(NameOrTag) ->
    Bin = to_bin(NameOrTag),
    case binary:split(Bin, <<":">>) of
        [Name] -> {Name, <<"latest">>};
        [Name, <<>>] -> {Name, <<"latest">>};
        [Name, Tag] -> {Name, Tag}
    end.

url_basename(URL) ->
    Path =
        case uri_string:parse(URL) of
            #{path := P} when is_binary(P), P =/= <<>> -> P;
            _ -> <<"download">>
        end,
    strip_ext(to_bin(filename:basename(Path))).

strip_ext(Bin) when is_binary(Bin) ->
    case filename:rootname(Bin) of
        <<>> -> Bin;
        Stripped -> Stripped
    end.

%% =============================================================================
%% Internal: pull pipeline
%% =============================================================================

do_pull(Spec, Name, Tag, FetchOpts, Overrides) ->
    case barrel_inference_server_fetch:fetch(Spec, FetchOpts) of
        {ok, BlobPath} -> persist_manifest_overrides(Spec, Name, Tag, BlobPath, Overrides);
        {error, _} = E -> E
    end.

persist_manifest_overrides(Spec, Name, Tag, BlobPath, Overrides) ->
    case persist_manifest(Spec, Name, Tag, BlobPath) of
        {ok, Manifest} when map_size(Overrides) > 0 ->
            Merged = apply_overrides(Manifest, Overrides),
            {ok, Root} = cache_root(),
            case barrel_inference_server_models_store:write(Root, Merged) of
                ok -> {ok, Merged};
                {error, _} = E -> E
            end;
        Other ->
            Other
    end.

apply_overrides(Manifest, Overrides) ->
    M1 =
        case maps:find(system, Overrides) of
            {ok, S} -> Manifest#{<<"system">> => S};
            error -> Manifest
        end,
    M2 =
        case maps:find(template, Overrides) of
            {ok, T} -> M1#{<<"chat_template">> => T};
            error -> M1
        end,
    case maps:find(parameters, Overrides) of
        {ok, Params} when map_size(Params) > 0 ->
            ExistingParams = maps:get(<<"parameters">>, M2, #{}),
            M2#{<<"parameters">> => maps:merge(ExistingParams, atom_keys_to_bin(Params))};
        _ ->
            M2
    end.

atom_keys_to_bin(M) ->
    maps:fold(
        fun
            (K, V, Acc) when is_binary(K) -> Acc#{K => V};
            (K, V, Acc) when is_atom(K) -> Acc#{atom_to_binary(K, utf8) => V}
        end,
        #{},
        M
    ).

persist_manifest(Spec, Name, Tag, BlobPath) ->
    BlobPathBin = to_bin(BlobPath),
    Metadata = read_metadata_safe(BlobPath),
    Manifest = build_manifest(Spec, Name, Tag, BlobPathBin, Metadata),
    {ok, Root} = cache_root(),
    case barrel_inference_server_models_store:write(Root, Manifest) of
        ok -> {ok, Manifest};
        {error, _} = E -> E
    end.

read_metadata_safe(BlobPath) ->
    case barrel_inference_server_gguf:read_metadata(BlobPath) of
        {ok, M} -> M;
        {error, _} -> #{}
    end.

build_manifest(Spec, Name, Tag, BlobPath, Metadata) ->
    Quant = barrel_inference_server_gguf:quantization(Metadata),
    Ctx = barrel_inference_server_gguf:context_length(Metadata),
    Tpl = barrel_inference_server_gguf:chat_template(Metadata),
    #{
        <<"name">> => Name,
        <<"tag">> => Tag,
        <<"spec">> => Spec,
        <<"digest">> => extract_digest(BlobPath),
        <<"blob_path">> => BlobPath,
        <<"size_bytes">> => filelib:file_size(BlobPath),
        <<"format">> => <<"gguf">>,
        <<"architecture">> => or_null(barrel_inference_server_gguf:architecture(Metadata)),
        <<"family">> => or_null(barrel_inference_server_gguf:family(Metadata)),
        <<"parameter_size">> => or_null(
            barrel_inference_server_gguf:parameter_size_label(Metadata)
        ),
        <<"quantization">> => or_null(Quant),
        <<"context_size">> => or_null(Ctx),
        <<"embedding_length">> => or_null(barrel_inference_server_gguf:embedding_length(Metadata)),
        <<"chat_template">> => or_null(Tpl),
        <<"loader">> => loader_opts(Quant, Ctx, Tpl),
        <<"modified_at">> => iso8601_now()
    }.

loader_opts(Quant, Ctx, Tpl) ->
    Base = #{
        <<"n_gpu_layers">> => 0,
        <<"n_ctx">> => default_int(Ctx, 4096),
        <<"n_batch">> => 512,
        <<"quant_type">> => or_null(Quant),
        <<"quant_bits">> => or_null(quant_bits(Quant))
    },
    Base1 = maybe_merge_tool_call(Base, detect_tool_call_format(Tpl)),
    maybe_merge_thinking(Base1, detect_thinking_markers(Tpl)).

maybe_merge_tool_call(Base, undefined) ->
    Base;
maybe_merge_tool_call(Base, {Name, Start, End}) ->
    Base#{
        <<"tool_call_format">> => Name,
        <<"tool_call_markers">> => #{
            <<"start">> => Start,
            <<"end">> => End
        }
    }.

maybe_merge_thinking(Base, undefined) ->
    Base;
maybe_merge_thinking(Base, {Start, End}) ->
    Base#{
        <<"thinking_markers">> => #{
            <<"start">> => Start,
            <<"end">> => End
        }
    }.

%% Scan the GGUF chat_template for the wire-format markers each
%% known family uses. First hit wins (none of the four overlap in
%% practice). Templates that match none fall through, leaving the
%% loader without `tool_call_markers' / `tool_call_format' so the
%% engine uses the legacy GBNF `text-response | tool-N' grammar.
%% Mirrors Ollama's auto-detect-at-pull-time pattern.
detect_tool_call_format(undefined) ->
    undefined;
detect_tool_call_format(<<>>) ->
    undefined;
detect_tool_call_format(Template) when is_binary(Template) ->
    Candidates = [
        {<<"qwen-xml">>, <<"<tool_call>">>, <<"</tool_call>">>},
        {<<"dsml">>, <<"<｜tool▁call▁begin｜>"/utf8>>, <<"<｜tool▁call▁end｜>"/utf8>>},
        {<<"llama-python-tag">>, <<"<|python_tag|>">>, <<"<|eom_id|>">>},
        {<<"mistral-tool-calls">>, <<"[TOOL_CALLS]">>, <<"</s>">>}
    ],
    first_match_marker(Template, Candidates).

first_match_marker(_, []) ->
    undefined;
first_match_marker(Template, [{Name, Start, End} | Rest]) ->
    case binary:match(Template, Start) of
        nomatch -> first_match_marker(Template, Rest);
        _ -> {Name, Start, End}
    end.

%% Scan the chat_template for known reasoning-block delimiters.
%% Two families ship today: `<think>...</think>' (Qwen3, QwQ,
%% DeepSeek-R1 lineage) and `<thinking>...</thinking>' (Claude-
%% distilled lookalikes). Templates that contain neither fall
%% through; the engine then treats reasoning text as regular
%% output. `<think>' is not a substring of `<thinking>' (next byte
%% after `<think' is `i', not `>') so order only matters for
%% templates that contain BOTH tags - none in practice.
detect_thinking_markers(undefined) ->
    undefined;
detect_thinking_markers(<<>>) ->
    undefined;
detect_thinking_markers(Template) when is_binary(Template) ->
    Candidates = [
        {<<"<think>">>, <<"</think>">>},
        {<<"<thinking>">>, <<"</thinking>">>}
    ],
    first_match_thinking(Template, Candidates).

first_match_thinking(_, []) ->
    undefined;
first_match_thinking(Template, [{Start, End} | Rest]) ->
    case binary:match(Template, Start) of
        nomatch -> first_match_thinking(Template, Rest);
        _ -> {Start, End}
    end.

quant_bits(undefined) -> undefined;
quant_bits(<<"f32">>) -> 32;
quant_bits(<<"f16">>) -> 16;
quant_bits(<<"bf16">>) -> 16;
quant_bits(<<"q2_", _/binary>>) -> 2;
quant_bits(<<"q3_", _/binary>>) -> 3;
quant_bits(<<"q4_", _/binary>>) -> 4;
quant_bits(<<"q5_", _/binary>>) -> 5;
quant_bits(<<"q6_", _/binary>>) -> 6;
quant_bits(<<"q8_", _/binary>>) -> 8;
quant_bits(<<"iq1_", _/binary>>) -> 1;
quant_bits(<<"iq2_", _/binary>>) -> 2;
quant_bits(<<"iq3_", _/binary>>) -> 3;
quant_bits(<<"iq4_", _/binary>>) -> 4;
quant_bits(_) -> undefined.

%% Recover the sha256 digest from the blob filename when it follows
%% the cache convention; otherwise fall back to digesting the file.
extract_digest(BlobPath) ->
    Base = filename:basename(BlobPath),
    case to_bin(Base) of
        <<"sha256-", Rest/binary>> ->
            case binary:split(Rest, <<".">>) of
                [Hex, _Ext] -> <<"sha256:", Hex/binary>>;
                _ -> compute_digest(BlobPath)
            end;
        _ ->
            compute_digest(BlobPath)
    end.

compute_digest(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, IO} ->
            try
                Hex = bin_to_hex(crypto:hash_final(seed_loop(IO, crypto:hash_init(sha256)))),
                <<"sha256:", Hex/binary>>
            after
                _ = file:close(IO)
            end;
        {error, _} ->
            null
    end.

seed_loop(IO, Ctx) ->
    case file:read(IO, 1024 * 1024) of
        {ok, Data} -> seed_loop(IO, crypto:hash_update(Ctx, Data));
        eof -> Ctx
    end.

bin_to_hex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

or_null(undefined) -> null;
or_null(V) -> V.

default_int(undefined, Default) -> Default;
default_int(N, _Default) when is_integer(N) -> N.

iso8601_now() ->
    Now = erlang:system_time(second),
    {{Y, Mo, D}, {H, M, S}} = calendar:system_time_to_universal_time(Now, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, M, S])
    ).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
