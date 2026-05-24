%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_models_store).
-moduledoc """
Pure filesystem CRUD over the registry's manifest files.

Manifest layout (under the cache root):

```
<root>/manifests/<name-encoded>/<tag>.json
```

`<name-encoded>` is the model name with forward slashes mapped to
colons so the directory tree stays flat. Tag is the bare filename;
extension is always `.json`. Writes are atomic (write-then-rename).

This module performs no HTTP, no GGUF parsing, no spec parsing; it
is a thin layer over `file:read_file/1` and `file:write_file/2`
that the registry façade uses.
""".

-export([
    list/1,
    read/3,
    write/2,
    delete/3,
    copy/5,
    encode_name/1,
    decode_name/1
]).

-export_type([manifest/0, name/0, tag/0]).

-type name() :: binary().
-type tag() :: binary().
-type manifest() :: #{binary() => term()}.

%% =============================================================================
%% Public API
%% =============================================================================

-spec list(file:name_all()) -> [manifest()].
list(Root) ->
    Dir = manifests_dir(Root),
    case file:list_dir(Dir) of
        {ok, NameDirs} ->
            lists:flatmap(fun(NameDir) -> list_tags(Dir, NameDir) end, NameDirs);
        {error, _} ->
            []
    end.

-spec read(file:name_all(), name(), tag()) ->
    {ok, manifest()} | {error, not_found | bad_manifest | term()}.
read(Root, Name, Tag) ->
    Path = manifest_path(Root, Name, Tag),
    case file:read_file(Path) of
        {ok, Bin} ->
            decode(Bin);
        {error, enoent} ->
            {error, not_found};
        {error, _} = E ->
            E
    end.

-spec write(file:name_all(), manifest()) -> ok | {error, term()}.
write(Root, Manifest) ->
    Name = maps:get(<<"name">>, Manifest),
    Tag = maps:get(<<"tag">>, Manifest),
    Path = manifest_path(Root, Name, Tag),
    Bin = iolist_to_binary(json:encode(Manifest)),
    write_atomic(Path, Bin).

-spec delete(file:name_all(), name(), tag()) -> ok | {error, not_found | term()}.
delete(Root, Name, Tag) ->
    Path = manifest_path(Root, Name, Tag),
    case file:delete(Path) of
        ok ->
            _ = prune_empty_name_dir(Root, Name),
            ok;
        {error, enoent} ->
            {error, not_found};
        {error, _} = E ->
            E
    end.

-spec copy(file:name_all(), name(), tag(), name(), tag()) -> ok | {error, term()}.
copy(Root, SrcName, SrcTag, DstName, DstTag) ->
    case read(Root, SrcName, SrcTag) of
        {ok, Manifest} ->
            New = Manifest#{
                <<"name">> => to_bin(DstName),
                <<"tag">> => to_bin(DstTag),
                <<"modified_at">> => iso8601_now()
            },
            write(Root, New);
        {error, _} = E ->
            E
    end.

%% Encode a model name into a directory-safe form by mapping `/`
%% to `:`. Decode is the inverse.
-spec encode_name(name()) -> binary().
encode_name(Name) ->
    binary:replace(to_bin(Name), <<"/">>, <<":">>, [global]).

-spec decode_name(binary()) -> binary().
decode_name(Bin) ->
    binary:replace(Bin, <<":">>, <<"/">>, [global]).

%% =============================================================================
%% Internal
%% =============================================================================

manifests_dir(Root) ->
    filename:join(Root, "manifests").

manifest_path(Root, Name, Tag) ->
    filename:join([
        manifests_dir(Root),
        encode_name(Name),
        <<(to_bin(Tag))/binary, ".json">>
    ]).

list_tags(ManifestsDir, NameEnc) ->
    NameDir = filename:join(ManifestsDir, NameEnc),
    case file:list_dir(NameDir) of
        {ok, Files} ->
            lists:filtermap(
                fun(F) -> read_tag(NameDir, F) end,
                Files
            );
        {error, _} ->
            []
    end.

read_tag(NameDir, F) ->
    case lists:suffix(".json", F) of
        true ->
            Path = filename:join(NameDir, F),
            case file:read_file(Path) of
                {ok, Bin} ->
                    case decode(Bin) of
                        {ok, M} -> {true, M};
                        _ -> false
                    end;
                _ ->
                    false
            end;
        false ->
            false
    end.

decode(Bin) ->
    try json:decode(Bin) of
        Manifest when is_map(Manifest) -> {ok, Manifest};
        _ -> {error, bad_manifest}
    catch
        _:_ -> {error, bad_manifest}
    end.

write_atomic(Path, Bin) ->
    Tmp = <<(to_bin(Path))/binary, ".tmp">>,
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Tmp, Bin) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> ok;
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

prune_empty_name_dir(Root, Name) ->
    NameDir = filename:join(manifests_dir(Root), encode_name(Name)),
    case file:list_dir(NameDir) of
        {ok, []} -> file:del_dir(NameDir);
        _ -> ok
    end.

iso8601_now() ->
    Now = erlang:system_time(second),
    {{Y, Mo, D}, {H, M, S}} = calendar:system_time_to_universal_time(Now, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, M, S])
    ).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
