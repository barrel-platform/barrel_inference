%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_fetch_resolvers).
-moduledoc """
Pure helpers for the fetch subsystem.

Two responsibilities:

  1. `parse/1` turn a user-supplied spec (binary or string) into a
     tagged tuple identifying the source.
  2. `resolve/1` given a parsed spec, build the request the worker
     should issue: GET URL, headers, expected sha256 (when known),
     and the desired output basename.

For HuggingFace the request is the LFS download URL; the worker
issues an HTTP HEAD before streaming to capture `X-Linked-ETag` (the
LFS sha256). For Ollama the resolver must contact the registry's
manifest endpoint to find the model layer's digest; that side-effect
lives in `resolve_ollama/3`.
""".

-export([
    parse/1,
    resolve/1,
    resolve/2,
    spec_canonical/1,
    spec_hash/1,
    hf_list_siblings/4,
    hf_pick_gguf/1
]).

-export_type([spec/0, parsed/0, resolved/0]).

-type spec() :: binary() | string().

-type parsed() ::
    {hf, Org :: binary(), Repo :: binary(), Path :: binary() | undefined, Revision :: binary()}
    | {ollama, Library :: binary(), Name :: binary(), Tag :: binary()}
    | {http, URL :: binary()}
    | {file, AbsPath :: binary()}.

-type resolved() :: #{
    method := get,
    url := binary(),
    headers := [{binary(), binary()}],
    expected_sha256 => binary(),
    out_basename := binary()
}.

%% =============================================================================
%% Parsing
%% =============================================================================

-spec parse(spec()) -> {ok, parsed()} | {error, term()}.
parse(Spec) when is_list(Spec) ->
    parse(unicode:characters_to_binary(Spec));
parse(<<"hf://", Rest/binary>>) ->
    parse_hf(Rest);
parse(<<"ollama://", Rest/binary>>) ->
    parse_ollama(Rest);
parse(<<"http://", _/binary>> = URL) ->
    {ok, {http, URL}};
parse(<<"https://", _/binary>> = URL) ->
    {ok, {http, URL}};
parse(<<"file://", Rest/binary>>) ->
    {ok, {file, Rest}};
parse(<<"/", _/binary>> = Abs) ->
    {ok, {file, Abs}};
parse(Other) ->
    {error, {unsupported_spec, Other}}.

parse_hf(Rest) ->
    {WithoutRev, Revision} = split_revision(Rest),
    case binary:split(WithoutRev, <<"/">>, [global]) of
        [Org, Repo] when byte_size(Org) > 0, byte_size(Repo) > 0 ->
            {ok, {hf, Org, Repo, undefined, Revision}};
        [Org, Repo | PathParts] when byte_size(Org) > 0, byte_size(Repo) > 0 ->
            Path = iolist_to_binary(lists:join($/, PathParts)),
            {ok, {hf, Org, Repo, Path, Revision}};
        _ ->
            {error, {bad_hf_spec, <<"hf://", Rest/binary>>}}
    end.

split_revision(Bin) ->
    case binary:split(Bin, <<"@">>) of
        [Path] -> {Path, <<"main">>};
        [Path, <<>>] -> {Path, <<"main">>};
        [Path, Rev] -> {Path, Rev}
    end.

parse_ollama(Rest) ->
    case binary:split(Rest, <<"/">>) of
        [Library, NameAndTag] when byte_size(Library) > 0, byte_size(NameAndTag) > 0 ->
            {Name, Tag} = split_tag(NameAndTag),
            case Name of
                <<>> -> {error, {bad_ollama_spec, <<"ollama://", Rest/binary>>}};
                _ -> {ok, {ollama, Library, Name, Tag}}
            end;
        _ ->
            {error, {bad_ollama_spec, <<"ollama://", Rest/binary>>}}
    end.

split_tag(Bin) ->
    case binary:split(Bin, <<":">>) of
        [Name] -> {Name, <<"latest">>};
        [Name, <<>>] -> {Name, <<"latest">>};
        [Name, Tag] -> {Name, Tag}
    end.

%% =============================================================================
%% Resolution
%% =============================================================================

%% `resolve/1` is the side-effect-free dispatch. HF and Ollama may need
%% network calls to upgrade their resolution (HEAD for the linked
%% ETag, GET for the manifest); those live in `resolve/2` so unit tests
%% can stay offline.
-spec resolve(parsed()) -> {ok, resolved()} | {error, term()}.
resolve({hf, _Org, _Repo, undefined, _Rev}) ->
    {error, hf_needs_network};
resolve({hf, Org, Repo, Path, Revision}) ->
    {ok, hf_resolved(Org, Repo, Path, Revision)};
resolve({http, URL}) ->
    {ok, http_resolved(URL)};
resolve({file, Abs}) ->
    {ok, file_resolved(Abs)};
resolve({ollama, _, _, _}) ->
    {error, ollama_needs_network}.

hf_resolved(Org, Repo, Path, Revision) ->
    URL = iolist_to_binary(
        [
            <<"https://huggingface.co/">>,
            Org,
            <<"/">>,
            Repo,
            <<"/resolve/">>,
            Revision,
            <<"/">>,
            Path
        ]
    ),
    #{
        method => get,
        url => URL,
        headers => hf_auth_headers() ++ [{<<"User-Agent">>, ua()}],
        out_basename => filename:basename(Path)
    }.

http_resolved(URL) ->
    #{
        method => get,
        url => URL,
        headers => [{<<"User-Agent">>, ua()}],
        out_basename => http_basename(URL)
    }.

file_resolved(Abs) ->
    #{method => get, url => Abs, headers => [], out_basename => filename:basename(Abs)}.

%% Two-step resolution. `Fetch` is a fun(URL, Headers) ->
%% {ok, Status, RespHeaders, Body :: binary()} | {error, term()}, so
%% the worker can plug in hackney without this module pulling it in.
-spec resolve(parsed(), fun((binary(), [{binary(), binary()}]) -> term())) ->
    {ok, resolved()} | {error, term()}.
resolve({ollama, Library, Name, Tag}, Fetch) when is_function(Fetch, 2) ->
    case ollama_fetch_manifest(Library, Name, Tag, Fetch) of
        {ok, Digest} -> {ok, ollama_resolved(Library, Name, Tag, Digest)};
        {error, _} = E -> E
    end;
resolve({hf, Org, Repo, undefined, Rev}, Fetch) when is_function(Fetch, 2) ->
    case hf_list_siblings(Org, Repo, Rev, Fetch) of
        {ok, Files} ->
            case hf_pick_gguf(Files) of
                {ok, Path} -> resolve({hf, Org, Repo, Path, Rev});
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
resolve(Other, _Fetch) ->
    resolve(Other).

%% List the file siblings of a HuggingFace repo. Returns the
%% `siblings` array from `/api/models/<org>/<repo>` as a list of
%% binary filenames. Network call goes through `Fetch`.
-spec hf_list_siblings(
    binary(), binary(), binary(), fun((binary(), [{binary(), binary()}]) -> term())
) ->
    {ok, [binary()]} | {error, term()}.
hf_list_siblings(Org, Repo, Rev, Fetch) ->
    URL = iolist_to_binary(
        [<<"https://huggingface.co/api/models/">>, Org, <<"/">>, Repo, <<"/revision/">>, Rev]
    ),
    Hdrs = hf_auth_headers() ++ [{<<"User-Agent">>, ua()}, {<<"Accept">>, <<"application/json">>}],
    case Fetch(URL, Hdrs) of
        {ok, 200, _, Body} when is_binary(Body) ->
            try json:decode(Body) of
                #{<<"siblings">> := Siblings} when is_list(Siblings) ->
                    Files = [F || #{<<"rfilename">> := F} <- Siblings, is_binary(F)],
                    {ok, Files};
                _ ->
                    {error, hf_no_siblings}
            catch
                _:Reason -> {error, {hf_manifest_parse, Reason}}
            end;
        {ok, 404, _, _} ->
            {error, {hf_repo_not_found, Org, Repo, Rev}};
        {ok, Status, _, _} ->
            {error, {hf_api_status, Status}};
        {error, _} = E ->
            E
    end.

%% From a list of repo files, pick the most useful GGUF. Preference
%% order: Q4_K_M, Q5_K_M, Q4_0, Q8_0, then any *.gguf alphabetically.
-spec hf_pick_gguf([binary()]) -> {ok, binary()} | {error, no_gguf}.
hf_pick_gguf(Files) ->
    Ggufs = [F || F <- Files, ends_with(F, <<".gguf">>)],
    case Ggufs of
        [] ->
            {error, no_gguf};
        _ ->
            Sorted = sort_by_quant_preference(Ggufs),
            {ok, hd(Sorted)}
    end.

sort_by_quant_preference(Files) ->
    [F || {_, F} <- lists:keysort(1, [{quant_score(F), F} || F <- Files])].

quant_score(F) ->
    Lower = string:lowercase(F),
    score_first_match(Lower, [
        {<<"q4_k_m">>, 0},
        {<<"q5_k_m">>, 1},
        {<<"q4_0">>, 2},
        {<<"q8_0">>, 3}
    ]).

score_first_match(_Lower, []) ->
    {99, undefined};
score_first_match(Lower, [{Needle, Score} | Rest]) ->
    case binary:match(Lower, Needle) of
        nomatch -> score_first_match(Lower, Rest);
        _ -> {Score, Lower}
    end.

ends_with(Bin, Suffix) ->
    BS = byte_size(Bin),
    SS = byte_size(Suffix),
    BS >= SS andalso binary:part(Bin, BS - SS, SS) =:= Suffix.

ollama_fetch_manifest(Library, Name, Tag, Fetch) ->
    ManifestURL = iolist_to_binary(
        [
            <<"https://registry.ollama.ai/v2/">>,
            Library,
            <<"/">>,
            Name,
            <<"/manifests/">>,
            Tag
        ]
    ),
    AcceptHdrs = [
        {<<"Accept">>, <<"application/vnd.docker.distribution.manifest.v2+json">>},
        {<<"User-Agent">>, ua()}
    ],
    case Fetch(ManifestURL, AcceptHdrs) of
        {ok, 200, _, Body} when is_binary(Body) -> ollama_pick_layer(Body);
        {ok, Status, _, _} -> {error, {ollama_manifest_status, Status}};
        {error, _} = E -> E
    end.

ollama_resolved(Library, Name, Tag, Digest) ->
    BlobURL = iolist_to_binary(
        [<<"https://registry.ollama.ai/v2/">>, Library, <<"/">>, Name, <<"/blobs/">>, Digest]
    ),
    Basename = iolist_to_binary([Library, <<"-">>, Name, <<"-">>, Tag, <<".gguf">>]),
    #{
        method => get,
        url => BlobURL,
        headers => [{<<"User-Agent">>, ua()}],
        expected_sha256 => strip_sha256_prefix(Digest),
        out_basename => Basename
    }.

%% =============================================================================
%% Spec canonicalisation (for stable cache keys)
%% =============================================================================

-spec spec_canonical(parsed()) -> binary().
spec_canonical({hf, Org, Repo, Path, Rev}) ->
    PathSegment =
        case Path of
            undefined -> <<>>;
            _ -> <<"/", Path/binary>>
        end,
    iolist_to_binary([<<"hf://">>, Org, <<"/">>, Repo, PathSegment, <<"@">>, Rev]);
spec_canonical({ollama, Library, Name, Tag}) ->
    iolist_to_binary([<<"ollama://">>, Library, <<"/">>, Name, <<":">>, Tag]);
spec_canonical({http, URL}) ->
    URL;
spec_canonical({file, Abs}) ->
    <<"file://", Abs/binary>>.

-spec spec_hash(parsed()) -> binary().
spec_hash(Parsed) ->
    Hex = bin_to_hex(crypto:hash(sha256, spec_canonical(Parsed))),
    binary:part(Hex, 0, 16).

%% =============================================================================
%% Internal
%% =============================================================================

ua() ->
    <<"barrel_inference_server/0.8.0 (+https://github.com/barrel-platform/barrel_inference)">>.

hf_auth_headers() ->
    case os:getenv("HF_TOKEN") of
        false -> [];
        "" -> [];
        Token -> [{<<"Authorization">>, iolist_to_binary([<<"Bearer ">>, Token])}]
    end.

http_basename(URL) ->
    Path =
        case uri_string:parse(URL) of
            #{path := P} when is_binary(P), P =/= <<>> -> P;
            #{path := P} when is_list(P), P =/= "" -> unicode:characters_to_binary(P);
            _ -> <<"download">>
        end,
    case filename:basename(Path) of
        <<>> -> <<"download">>;
        Base -> Base
    end.

ollama_pick_layer(Body) ->
    try json:decode(Body) of
        #{<<"layers">> := Layers} when is_list(Layers) ->
            case lists:search(fun is_model_layer/1, Layers) of
                {value, #{<<"digest">> := Digest}} when is_binary(Digest) ->
                    {ok, Digest};
                _ ->
                    {error, ollama_no_model_layer}
            end;
        _ ->
            {error, ollama_bad_manifest}
    catch
        _:Reason ->
            {error, {ollama_manifest_parse, Reason}}
    end.

is_model_layer(#{<<"mediaType">> := <<"application/vnd.ollama.image.model">>}) -> true;
is_model_layer(_) -> false.

strip_sha256_prefix(<<"sha256:", Hex/binary>>) -> Hex;
strip_sha256_prefix(Hex) -> Hex.

bin_to_hex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).
