%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_fetch_worker).
-moduledoc """
Transient worker that streams a single fetch.

Lifecycle:

1. `start_link/3` is called from `erllama_server_fetch_sup` with the
   parsed spec, the per-call options, and the pid of
   `erllama_server_fetch_srv`.
2. The worker resolves the request (HF HEAD for `X-Linked-ETag`,
   Ollama manifest for the model layer digest) inline, then issues
   an async-once GET via hackney with a `Range` header when a
   `.part` file is present.
3. Each chunk is appended to the `.part` file and folded into a
   running sha256 context. Progress is rate-limited to ~1 update per
   100 ms and forwarded to the srv as a cast.
4. On success the `.part` is renamed to
   `<root>/blobs/sha256-<hex>.gguf`, a small
   `<root>/refs/<spec_hash>.ref` file is written pointing at the
   blob, and `{done, Ref, {ok, Path}}` is cast to the srv.
5. Errors are reported via `{done, Ref, {error, Reason}}`. The
   `.part` file is preserved on transient failure so the next call
   can resume; on sha256 mismatch it is removed.
""".

-export([start_link/3]).
-export([init/3]).

-include_lib("kernel/include/file.hrl").

%% Hackney 4.0.0's `request_async` returns `{ok, self()}` (a connection
%% pid) per `hackney_conn:do_request_async/9`, but its spec advertises
%% `{ok, reference()}` and `stream_next/1` then expects a `pid()`. We
%% pass the value through verbatim; runtime is fine, dialyzer just
%% sees the broken specs. Suppress the resulting cascade.
-dialyzer(
    {nowarn_function, [
        stream/6,
        stream_with_redirects/7,
        open_stream/6,
        stream_recv/10,
        handle_ok_status/2,
        init_stream/6,
        consume/5,
        try_close/1,
        advance/1,
        stream_loop/1,
        on_chunk/2,
        on_done/1,
        update_stream/2,
        emit_progress/1,
        wait_status/2,
        wait_headers/2,
        drain/2,
        finalize/5,
        promote/4,
        place_blob/2,
        publish/3,
        write_ref/3,
        copy_then_delete/2,
        file_mode/1,
        resume_for_status/3,
        total_size/3,
        content_length_total/1,
        parse_total_from_range/1,
        safe_integer/1,
        normalise_hex/1,
        bin_to_hex/1
    ]}
).

-define(PROGRESS_INTERVAL_MS, 100).

-record(stream, {
    ref :: reference(),
    io :: file:io_device(),
    ctx :: term(),
    bytes :: non_neg_integer(),
    total :: non_neg_integer() | undefined,
    timeout :: pos_integer(),
    srv :: pid(),
    self_ref :: pid(),
    last_emit :: integer()
}).

-spec start_link(erllama_server_fetch_resolvers:parsed(), map(), pid()) -> {ok, pid()}.
start_link(Parsed, Opts, SrvPid) when is_map(Opts), is_pid(SrvPid) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Parsed, Opts, SrvPid])}.

-spec init(erllama_server_fetch_resolvers:parsed(), map(), pid()) -> no_return().
init(Parsed, Opts, SrvPid) ->
    Self = self(),
    Result =
        try run(Parsed, Opts, SrvPid, Self) of
            {ok, _Path} = OK -> OK;
            {error, _} = E -> E
        catch
            Class:Reason:Stack ->
                {error, {Class, Reason, Stack}}
        end,
    gen_server:cast(SrvPid, {done, Self, Result}),
    exit(normal).

run({file, AbsBin}, _Opts, _SrvPid, _Self) ->
    Abs = unicode:characters_to_list(AbsBin),
    case filelib:is_regular(Abs) of
        true -> {ok, Abs};
        false -> {error, {enoent, Abs}}
    end;
run(Parsed, Opts, SrvPid, Self) ->
    {ok, Root} = erllama_server_fetch:cache_root(),
    ok = ensure_dirs(Root),
    run_remote(Parsed, Opts, SrvPid, Self, Root).

run_remote(Parsed, Opts, SrvPid, Self, Root) ->
    gen_server:cast(SrvPid, {phase, Self, resolving}),
    case resolve(Parsed, Opts) of
        {ok, Upgraded, Resolved0} ->
            gen_server:cast(SrvPid, {phase, Self, streaming}),
            Resolved = maybe_attach_caller_sha(Resolved0, Opts),
            stream(Upgraded, Resolved, Opts, SrvPid, Self, Root);
        {error, _} = E ->
            E
    end.

%% Caller-supplied sha256 takes precedence over a source-derived one.
maybe_attach_caller_sha(Resolved, #{sha256 := Sha}) when is_binary(Sha) ->
    Resolved#{expected_sha256 => Sha};
maybe_attach_caller_sha(Resolved, _Opts) ->
    Resolved.

resolve({hf, Org, Repo, undefined, Rev}, Opts) ->
    resolve_hf_no_path(Org, Repo, Rev, Opts);
resolve({hf, _, _, _, _} = Parsed, Opts) ->
    case erllama_server_fetch_resolvers:resolve(Parsed) of
        {ok, R} -> {ok, Parsed, hf_attach_etag(R, Opts)};
        E -> E
    end;
resolve({ollama, _, _, _} = Parsed, Opts) ->
    Fetch = fun(URL, Hdrs) -> http_get_body(URL, Hdrs, Opts) end,
    case erllama_server_fetch_resolvers:resolve(Parsed, Fetch) of
        {ok, R} -> {ok, Parsed, R};
        E -> E
    end;
resolve(Parsed, _Opts) ->
    case erllama_server_fetch_resolvers:resolve(Parsed) of
        {ok, R} -> {ok, Parsed, R};
        E -> E
    end.

resolve_hf_no_path(Org, Repo, Rev, Opts) ->
    Fetch = fun(URL, Hdrs) -> http_get_body(URL, Hdrs, Opts) end,
    case erllama_server_fetch_resolvers:hf_list_siblings(Org, Repo, Rev, Fetch) of
        {ok, Files} -> resolve_hf_pick(Org, Repo, Rev, Files, Opts);
        {error, _} = E -> E
    end.

resolve_hf_pick(Org, Repo, Rev, Files, Opts) ->
    case erllama_server_fetch_resolvers:hf_pick_gguf(Files) of
        {ok, Path} -> resolve({hf, Org, Repo, Path, Rev}, Opts);
        {error, _} = E -> E
    end.

%% Best-effort capture of the LFS sha256 from a HEAD probe. Failures
%% are non-fatal; we just lose integrity verification for that file.
hf_attach_etag(R, Opts) ->
    URL = maps:get(url, R),
    Hdrs = maps:get(headers, R),
    case http_head(URL, Hdrs, Opts) of
        {ok, _Status, RespHdrs} ->
            case header(RespHdrs, <<"x-linked-etag">>) of
                undefined ->
                    R;
                Quoted ->
                    Hex = strip_etag_quotes(Quoted),
                    R#{expected_sha256 => Hex}
            end;
        _ ->
            R
    end.

%% =============================================================================
%% Streaming
%% =============================================================================

stream(Parsed, Resolved, Opts, SrvPid, Self, Root) ->
    stream_with_redirects(Parsed, Resolved, Opts, SrvPid, Self, Root, 5).

stream_with_redirects(_Parsed, _Resolved, _Opts, _SrvPid, _Self, _Root, 0) ->
    {error, too_many_redirects};
stream_with_redirects(Parsed, Resolved, Opts, SrvPid, Self, Root, N) ->
    case open_stream(Parsed, Resolved, Opts, SrvPid, Self, Root) of
        {redirect, NewURL} ->
            %% Hackney 4 async mode hands redirects back; retry
            %% with the new location and a fresh connection.
            Resolved1 = Resolved#{url => NewURL},
            stream_with_redirects(Parsed, Resolved1, Opts, SrvPid, Self, Root, N - 1);
        Other ->
            Other
    end.

open_stream(Parsed, Resolved, Opts, SrvPid, Self, Root) ->
    SpecHash = erllama_server_fetch_resolvers:spec_hash(Parsed),
    Tmp = filename:join([Root, "tmp", <<SpecHash/binary, ".part">>]),
    {Offset, HashCtx0} = resume_state(Tmp),
    URL = maps:get(url, Resolved),
    Hdrs = build_headers(maps:get(headers, Resolved), Offset),
    Timeout = maps:get(timeout, Opts, 120_000),
    case hackney:request(get, URL, Hdrs, <<>>, hackney_options(Timeout)) of
        {ok, ClientRef} ->
            stream_recv(
                ClientRef,
                Tmp,
                Offset,
                HashCtx0,
                Timeout,
                SrvPid,
                Self,
                Resolved,
                Parsed,
                Root
            );
        {error, _} = E ->
            E
    end.

resume_state(Tmp) ->
    case file:read_file_info(Tmp) of
        {ok, #file_info{size = N}} when N > 0 -> {N, hash_seed(Tmp)};
        _ -> {0, crypto:hash_init(sha256)}
    end.

build_headers(Hdrs, 0) ->
    Hdrs;
build_headers(Hdrs, Offset) ->
    Range = iolist_to_binary([<<"bytes=">>, integer_to_binary(Offset), <<"-">>]),
    [{<<"Range">>, Range} | Hdrs].

hackney_options(Timeout) ->
    %% Force HTTP/1.1 ALPN: hackney 4.0.0 async streaming wedges
    %% silently on HTTP/2 connections (no `hackney_response`
    %% messages ever arrive). Sync mode is fine, but we need async
    %% for chunked downloads.
    [
        {async, once},
        {stream_to, self()},
        {protocols, [http1]}
        | common_opts(Timeout)
    ].

-record(rcv, {
    client :: pid(),
    tmp :: file:filename_all(),
    offset :: non_neg_integer(),
    hash :: term(),
    timeout :: pos_integer(),
    srv :: pid(),
    self_ref :: pid(),
    resolved :: erllama_server_fetch_resolvers:resolved(),
    parsed :: erllama_server_fetch_resolvers:parsed(),
    root :: file:filename_all()
}).

stream_recv(ClientRef, Tmp, Offset, HashCtx0, Timeout, SrvPid, Self, Resolved, Parsed, Root) ->
    R = #rcv{
        client = ClientRef,
        tmp = Tmp,
        offset = Offset,
        hash = HashCtx0,
        timeout = Timeout,
        srv = SrvPid,
        self_ref = Self,
        resolved = Resolved,
        parsed = Parsed,
        root = Root
    },
    case wait_status(ClientRef, Timeout) of
        {ok, Status} when Status =:= 200; Status =:= 206 -> handle_ok_status(Status, R);
        {ok, Status} ->
            drain(ClientRef, Timeout),
            {error, {http_status, Status}};
        {redirect, _} = Redir ->
            drain(ClientRef, Timeout),
            Redir;
        {error, _} = E ->
            E
    end.

handle_ok_status(Status, #rcv{client = ClientRef, timeout = Timeout} = R) ->
    case wait_headers(ClientRef, Timeout) of
        {ok, RespHdrs} ->
            {RealOffset, HashCtx} = resume_for_status(Status, R#rcv.offset, R#rcv.hash),
            {ok, IO} = file:open(R#rcv.tmp, file_mode(RealOffset)),
            State = init_stream(R, IO, HashCtx, RealOffset, Status, RespHdrs),
            ok = emit_progress(State),
            consume(advance(State), R#rcv.tmp, R#rcv.resolved, R#rcv.parsed, R#rcv.root);
        {error, _} = E ->
            drain(ClientRef, Timeout),
            E
    end.

init_stream(R, IO, HashCtx, Offset, Status, RespHdrs) ->
    #stream{
        ref = R#rcv.client,
        io = IO,
        ctx = HashCtx,
        bytes = Offset,
        total = total_size(Status, RespHdrs, Offset),
        timeout = R#rcv.timeout,
        srv = R#rcv.srv,
        self_ref = R#rcv.self_ref,
        last_emit = erlang:monotonic_time(millisecond)
    }.

resume_for_status(206, Offset, HashCtx) -> {Offset, HashCtx};
resume_for_status(200, _Offset, _HashCtx) -> {0, crypto:hash_init(sha256)}.

consume(State, Tmp, Resolved, Parsed, Root) ->
    case stream_loop(State) of
        {ok, FinalCtx, FinalState} ->
            ok = file:close(FinalState#stream.io),
            FinalHex = bin_to_hex(crypto:hash_final(FinalCtx)),
            finalize(Tmp, FinalHex, Resolved, Parsed, Root);
        {error, Reason, FinalState} ->
            try_close(FinalState#stream.io),
            {error, Reason}
    end.

try_close(IO) ->
    try
        file:close(IO)
    catch
        _:_ -> ok
    end.

%% Advance the async-once stream by one message slot.
advance(#stream{ref = Ref} = S) ->
    ok = hackney:stream_next(Ref),
    S.

stream_loop(#stream{ref = Ref, timeout = Timeout} = S) ->
    receive
        {hackney_response, Ref, Bin} when is_binary(Bin) -> on_chunk(Bin, S);
        {hackney_response, Ref, done} -> on_done(S);
        {hackney_response, Ref, {error, Reason}} -> {error, Reason, S};
        {hackney_response, Ref, {redirect, Loc, _}} -> {error, {unfollowed_redirect, Loc}, S};
        _Other -> stream_loop(S)
    after Timeout ->
        _ = hackney:stop_async(Ref),
        {error, recv_timeout, S}
    end.

on_chunk(Bin, S) ->
    case file:write(S#stream.io, Bin) of
        ok -> stream_loop(advance(update_stream(S, Bin)));
        {error, WriteReason} -> {error, {write_failed, WriteReason}, S}
    end.

on_done(S) ->
    ok = emit_progress(S),
    {ok, S#stream.ctx, S}.

update_stream(S, Bin) ->
    Bytes = S#stream.bytes + byte_size(Bin),
    Ctx = crypto:hash_update(S#stream.ctx, Bin),
    Now = erlang:monotonic_time(millisecond),
    LastEmit =
        case Now - S#stream.last_emit >= ?PROGRESS_INTERVAL_MS of
            true ->
                ok = emit_progress(S#stream{bytes = Bytes}),
                Now;
            false ->
                S#stream.last_emit
        end,
    S#stream{ctx = Ctx, bytes = Bytes, last_emit = LastEmit}.

emit_progress(#stream{srv = SrvPid, self_ref = Self, bytes = Bytes, total = Total}) ->
    gen_server:cast(SrvPid, {progress, Self, Bytes, Total}),
    ok.

%% =============================================================================
%% Status / header reception (async-once)
%% =============================================================================

wait_status(Ref, Timeout) ->
    receive
        {hackney_response, Ref, {status, Status, _Reason}} ->
            ok = hackney:stream_next(Ref),
            {ok, Status};
        {hackney_response, Ref, {error, Reason}} ->
            {error, Reason};
        {hackney_response, Ref, {redirect, Loc, _}} ->
            {redirect, Loc};
        {hackney_response, Ref, {see_other, Loc, _}} ->
            {redirect, Loc};
        _Other ->
            wait_status(Ref, Timeout)
    after Timeout ->
        _ = hackney:stop_async(Ref),
        {error, status_timeout}
    end.

wait_headers(Ref, Timeout) ->
    receive
        {hackney_response, Ref, {headers, Hdrs}} ->
            {ok, Hdrs};
        {hackney_response, Ref, {error, Reason}} ->
            {error, Reason};
        _Other ->
            wait_headers(Ref, Timeout)
    after Timeout ->
        _ = hackney:stop_async(Ref),
        {error, headers_timeout}
    end.

%% Async-once gives us one message at a time and only on demand. The
%% body would never arrive without further `stream_next` calls, so
%% just abort the request and let the gen_statem disappear.
drain(Ref, _Timeout) ->
    _ = hackney:stop_async(Ref),
    ok.

%% =============================================================================
%% Finalisation: rename .part -> blob, write ref, verify if we have a
%% caller- or source-supplied digest.
%% =============================================================================

finalize(Tmp, FinalHex, Resolved, Parsed, Root) ->
    case maps:find(expected_sha256, Resolved) of
        {ok, Expected} ->
            ExpectedHex = normalise_hex(Expected),
            case ExpectedHex =:= FinalHex of
                true ->
                    promote(Tmp, FinalHex, Parsed, Root);
                false ->
                    _ = file:delete(Tmp),
                    {error, {sha256_mismatch, FinalHex, ExpectedHex}}
            end;
        error ->
            promote(Tmp, FinalHex, Parsed, Root)
    end.

promote(Tmp, FinalHex, Parsed, Root) ->
    BlobName = iolist_to_binary([<<"sha256-">>, FinalHex, <<".gguf">>]),
    Blob = filename:join([Root, "blobs", BlobName]),
    case place_blob(Tmp, Blob) of
        ok -> publish(Root, Parsed, Blob);
        {error, _} = E -> E
    end.

%% A finalised .part lands at <root>/blobs/sha256-<hex>.gguf via one
%% of three paths: same-FS rename, cross-FS copy, or adopt-existing
%% (a concurrent worker already published the byte-identical blob).
place_blob(Tmp, Blob) ->
    case file:rename(Tmp, Blob) of
        ok -> ok;
        {error, exdev} -> copy_then_delete(Tmp, Blob);
        {error, eexist} -> file:delete(Tmp);
        {error, _} = E -> E
    end.

publish(Root, Parsed, Blob) ->
    ok = write_ref(Root, Parsed, Blob),
    {ok, unicode:characters_to_list(Blob)}.

write_ref(Root, Parsed, Blob) ->
    SpecHash = erllama_server_fetch_resolvers:spec_hash(Parsed),
    Ref = filename:join([Root, "refs", <<SpecHash/binary, ".ref">>]),
    file:write_file(Ref, unicode:characters_to_binary(Blob)).

copy_then_delete(Src, Dst) ->
    case file:copy(Src, Dst) of
        {ok, _} -> file:delete(Src);
        {error, _} = E -> E
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

ensure_dirs(Root) ->
    ok = filelib:ensure_path(filename:join(Root, "blobs")),
    ok = filelib:ensure_path(filename:join(Root, "refs")),
    ok = filelib:ensure_path(filename:join(Root, "tmp")),
    ok.

file_mode(0) -> [raw, write, binary];
file_mode(_N) -> [raw, append, binary].

hash_seed(Path) ->
    {ok, IO} = file:open(Path, [raw, read, binary]),
    try
        seed_loop(IO, crypto:hash_init(sha256))
    after
        file:close(IO)
    end.

seed_loop(IO, Ctx) ->
    case file:read(IO, 1024 * 1024) of
        {ok, Data} -> seed_loop(IO, crypto:hash_update(Ctx, Data));
        eof -> Ctx;
        {error, _} = E -> error(E)
    end.

total_size(206, RespHdrs, _Offset) ->
    case header(RespHdrs, <<"content-range">>) of
        undefined -> content_length_total(RespHdrs);
        Range -> parse_total_from_range(Range)
    end;
total_size(200, RespHdrs, _Offset) ->
    content_length_total(RespHdrs).

content_length_total(RespHdrs) ->
    case header(RespHdrs, <<"content-length">>) of
        undefined -> undefined;
        N -> safe_integer(N)
    end.

parse_total_from_range(Bin) ->
    %% "bytes <start>-<end>/<total>"
    case binary:split(Bin, <<"/">>) of
        [_, Total] -> safe_integer(Total);
        _ -> undefined
    end.

safe_integer(<<"*">>) ->
    undefined;
safe_integer(B) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> undefined
    end;
safe_integer(L) when is_list(L) ->
    safe_integer(unicode:characters_to_binary(L)).

header(Hdrs, NameLower) ->
    case
        lists:search(
            fun({K, _}) ->
                lower(to_bin(K)) =:= NameLower
            end,
            Hdrs
        )
    of
        {value, {_, V}} -> to_bin(V);
        false -> undefined
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

lower(B) ->
    list_to_binary(string:lowercase(binary_to_list(B))).

strip_etag_quotes(<<$", Rest/binary>>) ->
    Sz = byte_size(Rest),
    case Sz > 0 andalso binary:at(Rest, Sz - 1) =:= $" of
        true -> binary:part(Rest, 0, Sz - 1);
        false -> Rest
    end;
strip_etag_quotes(B) ->
    B.

normalise_hex(B) when is_binary(B) ->
    case byte_size(B) of
        32 -> bin_to_hex(B);
        64 -> string:lowercase(B);
        _ -> B
    end.

bin_to_hex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

%% =============================================================================
%% Sync HTTP helpers (HEAD probe + Ollama manifest GET).
%% =============================================================================

http_head(URL, Hdrs, Opts) ->
    case hackney:request(head, URL, Hdrs, <<>>, sync_opts(Opts)) of
        {ok, Status, RespHdrs} -> {ok, Status, RespHdrs};
        {ok, Status, RespHdrs, _Body} -> {ok, Status, RespHdrs};
        {error, _} = E -> E
    end.

http_get_body(URL, Hdrs, Opts) ->
    case hackney:request(get, URL, Hdrs, <<>>, sync_opts(Opts)) of
        {ok, Status, RespHdrs, Body} when is_binary(Body) -> {ok, Status, RespHdrs, Body};
        {error, _} = E -> E
    end.

sync_opts(Opts) ->
    common_opts(maps:get(timeout, Opts, 15000)).

common_opts(Timeout) ->
    [
        {follow_redirect, true},
        {max_redirect, 5},
        {connect_timeout, Timeout},
        {recv_timeout, Timeout}
    ].
