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
    persist_manifest_overrides/5,
    cache_root/0,
    resolve_n_seq_max/1,
    effective_context_size/1
]).

-export_type([manifest/0, name_or_tag/0, pull_opts/0]).

%% Cap the as-pulled default context. A model may advertise a huge native
%% context (e.g. 262144); baking that as the load default would allocate tens
%% of GB of KV. Operators raise it per-model via /api/edit num_ctx or the
%% server-wide max_context_size.
-define(DEFAULT_PULL_MAX_CTX, 32768).

%% Default engine seq-pool size (and, coupled, the server's admission
%% concurrency) when a manifest does not pin one. Safe at 4 ONLY because
%% the loader sets `kv_unified => true': with the unified KV cache a
%% single sequence may use the full `n_ctx' and the n_seq_max sequences
%% share that buffer, instead of llama.cpp's default of splitting n_ctx
%% into n_ctx/n_seq_max per sequence (which left ~8192 per request at
%% n_seq_max=4 and decode-failed on large prompts). Drives BOTH the engine
%% seq pool and admission concurrency (pool_policy_for/1) via
%% resolve_n_seq_max/1, so the two never drift. `admission_on_full=error'
%% turns a genuinely full pool into a fast retryable 503, not a wedge.
-define(DEFAULT_N_SEQ_MAX, 4).

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
    Ctx = cap_ctx(barrel_inference_server_gguf:context_length(Metadata)),
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
        <<"loader">> => loader_opts(
            Quant, Ctx, Tpl, barrel_inference_server_gguf:is_embedding_model(Metadata)
        ),
        <<"modified_at">> => iso8601_now()
    }.

%% Resolve the engine seq-pool size from a manifest, shared by the loader
%% (engine `context_opts.n_seq_max') and the server's admission concurrency
%% (`barrel_inference_server_config:pool_policy_for/1') so both layers use the
%% same number. Precedence: `parameters.num_seq_max' (operator /api/edit) >
%% `loader.n_seq_max' (as-pulled) > ?DEFAULT_N_SEQ_MAX.
-spec resolve_n_seq_max(manifest()) -> pos_integer().
resolve_n_seq_max(Manifest) when is_map(Manifest) ->
    Params = maps:get(<<"parameters">>, Manifest, #{}),
    Loader = maps:get(<<"loader">>, Manifest, #{}),
    case maps:get(<<"num_seq_max">>, Params, maps:get(<<"n_seq_max">>, Loader, undefined)) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_N_SEQ_MAX
    end.

%% Effective context the model loads with, capped by the server-wide
%% `max_context_size'. Precedence: `parameters.num_ctx' (operator
%% /api/edit override) > manifest `context_size' (as pulled).
%% `undefined' only when neither is set. The loader resolves n_ctx
%% through this same function so the reported context never drifts
%% from the loaded one; a `num_ctx' override is reflected in /api/show
%% without re-deriving the manifest.
-spec effective_context_size(manifest()) -> non_neg_integer() | undefined.
effective_context_size(Manifest) when is_map(Manifest) ->
    Params = maps:get(<<"parameters">>, Manifest, #{}),
    Requested =
        case maps:get(<<"num_ctx">>, Params, undefined) of
            undefined -> maps:get(<<"context_size">>, Manifest, undefined);
            Override -> Override
        end,
    case Requested of
        N when is_integer(N) ->
            min(N, application:get_env(barrel_inference_server, max_context_size, 4096));
        _ ->
            undefined
    end.

loader_opts(Quant, Ctx, Tpl, IsEmbed) ->
    Base0 = #{
        <<"n_gpu_layers">> => 0,
        <<"n_ctx">> => default_int(Ctx, 4096),
        <<"n_batch">> => 512,
        <<"quant_type">> => or_null(Quant),
        <<"quant_bits">> => or_null(quant_bits(Quant))
    },
    %% Embedding GGUFs load with the context in embeddings mode (the loader
    %% maps this to context_opts.embeddings); generative models stay unflagged.
    Base =
        case IsEmbed of
            true -> Base0#{<<"embeddings">> => true};
            false -> Base0
        end,
    Base1 = maybe_merge_tool_call(Base, detect_tool_call_format(Tpl)),
    maybe_merge_thinking(Base1, detect_thinking_markers(Tpl)).

cap_ctx(undefined) -> undefined;
cap_ctx(N) when is_integer(N) -> min(N, ?DEFAULT_PULL_MAX_CTX).

maybe_merge_tool_call(Base, undefined) ->
    Base;
maybe_merge_tool_call(Base, {Name, undefined, undefined}) ->
    %% Marker-less family (e.g. `llama-pythonic'): the family opts into
    %% the handlers' post-parse path on `buf_text' rather than the
    %% engine's native marker capture, so the manifest carries only
    %% the format name. No `tool_call_markers' is set, which keeps
    %% `barrel_inference_server_tool_format:native_turn/1' returning
    %% `none' for the request - the request still streams normally and
    %% the handler post-parses on done.
    Base#{<<"tool_call_format">> => Name};
maybe_merge_tool_call(Base, {Name, Start, End}) ->
    Base#{
        <<"tool_call_format">> => Name,
        <<"tool_call_markers">> => maybe_add_payload_markers(
            #{
                <<"start">> => Start,
                <<"end">> => End
            },
            Name
        )
    }.

%% Per-family payload markers: `mistral-args` uses `[ARGS]` as the inner
%% separator between the function name and the JSON arguments. The
%% engine treats `[ARGS]` as `payload_start`, which flips sampling from
%% the greedy syntax sampler to the request's normal sampler for the
%% rest of the span - without this the greedy sampler tends to lock
%% onto `[TOOL_CALLS]` after the args close and spam empty calls.
maybe_add_payload_markers(M, <<"mistral-args">>) ->
    M#{<<"payload_start">> => <<"[ARGS]">>};
maybe_add_payload_markers(M, _) ->
    M.

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
    %% Qwen3-Coder shares the `<tool_call>' markers with Qwen2.5 but emits a
    %% nested `<function=...><parameter=...>' body, not JSON-in-tags. Both
    %% templates contain `<tool_call>', so the generic scan would always pick
    %% `qwen-xml'; the `<function=' literal is unique to the Qwen3-Coder call
    %% format, so check it first.
    %%
    %% Mistral's tekken-tokenizer families (Devstral-2-2512,
    %% Mistral-Small-3.x, Magistral, Ministral, recent Codestral) emit
    %% `[TOOL_CALLS]<name>[ARGS]<json>' per call (with `</s>' only at the
    %% very end). The old `mistral-tool-calls' family parses the v3 JSON-
    %% array shape; both contain `[TOOL_CALLS]', so disambiguate by the
    %% `[ARGS]' marker, checked BEFORE the generic candidate scan.
    %% Llama 3.2 (1B, 3B) and Llama 3.3 70B Instruct emit zero-shot tool
    %% calls as a pythonic call list `[func(args), ...]<|eot_id|>',
    %% without the Llama 3.1 `<|python_tag|>...<|eom_id|>' envelope. The
    %% chat templates for these models mention `pythonic' or `python
    %% list' in their tool instructions and do NOT carry `<|python_tag|>'.
    %% Disambiguate from 3.1 by the absence of `<|python_tag|>'. The
    %% family is marker-less (no engine-side capture); the return tuple
    %% carries `undefined' marker fields and `maybe_merge_tool_call/2'
    %% emits `tool_call_format' WITHOUT `tool_call_markers'.
    %%
    %% Special-case detectors run BEFORE the generic candidate scan;
    %% each is a `{Predicate, ReturnTuple}' pair walked in order, first
    %% match wins. Generic scan falls through when no special-case
    %% predicate matches.
    SpecialCases = [
        {fun is_qwen3_coder_template/1,
            {<<"qwen3-coder">>, <<"<tool_call>">>, <<"</tool_call>">>}},
        {fun is_mistral_args_template/1,
            {<<"mistral-args">>, <<"[TOOL_CALLS]">>, <<"</s>">>}},
        {fun is_llama_pythonic_template/1, {<<"llama-pythonic">>, undefined, undefined}},
        {fun is_phi4_functools_template/1, {<<"phi4-functools">>, undefined, undefined}}
    ],
    case first_matching_special(SpecialCases, Template) of
        {ok, Result} -> Result;
        none -> first_match_marker(Template, Candidates)
    end.

first_matching_special([], _Template) ->
    none;
first_matching_special([{Pred, Result} | Rest], Template) ->
    case Pred(Template) of
        true -> {ok, Result};
        false -> first_matching_special(Rest, Template)
    end.

is_qwen3_coder_template(Template) ->
    binary:match(Template, <<"<tool_call>">>) =/= nomatch andalso
        binary:match(Template, <<"<function=">>) =/= nomatch.

%% Llama 3.2 / 3.3 zero-shot pythonic detection. Templates that have
%% `<|python_tag|>' (Llama 3.1's signature marker) continue to detect
%% as `llama-python-tag'. Templates that do NOT have `<|python_tag|>'
%% AND mention pythonic format detect as the new `llama-pythonic'
%% family. `<|eot_id|>' is present in every Llama 3.x template and is
%% used here as a Llama-family anchor.
is_llama_pythonic_template(Template) ->
    Has = fun(M) -> binary:match(Template, M) =/= nomatch end,
    Has(<<"<|eot_id|>">>) andalso
        not Has(<<"<|python_tag|>">>) andalso
        (Has(<<"pythonic">>) orelse Has(<<"python list">>)).

%% Phi-4-mini-instruct / Phi-4-multimodal-instruct. The chat template
%% renders the literal `functools[' prefix for tool-call output AND
%% wraps the SYSTEM-block tool declarations in `<|tool|>...<|/tool|>'
%% (vocab IDs 200023 / 200024). Both markers together uniquely
%% identify Phi-4 with tool calling - matching just `functools[' would
%% false-positive on prose templates that mention the token.
is_phi4_functools_template(Template) ->
    binary:match(Template, <<"functools[">>) =/= nomatch andalso
        binary:match(Template, <<"<|tool|>">>) =/= nomatch.

%% Require `[ARGS]' to appear AFTER `[TOOL_CALLS]' in the template (not
%% just anywhere), so an old-Mistral template that mentions `[ARGS]' in
%% surrounding instructions or documentation cannot get misclassified
%% as the new format.
is_mistral_args_template(Template) ->
    case binary:match(Template, <<"[TOOL_CALLS]">>) of
        nomatch ->
            false;
        {P, L} ->
            After = binary:part(Template, P + L, byte_size(Template) - (P + L)),
            binary:match(After, <<"[ARGS]">>) =/= nomatch
    end.

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
