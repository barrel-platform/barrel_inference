%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_fetch_worker).
-moduledoc """
Transient worker that streams a single fetch.

Lifecycle:

1. `start_link/3` is called from `barrel_inference_server_fetch_sup` with the
   parsed spec, the per-call options, and the pid of
   `barrel_inference_server_fetch_srv`.
2. The worker resolves the request (HF HEAD for `X-Linked-ETag`,
   Ollama manifest for the model layer digest) inline, then issues
   a push-stream GET via livery_client with `flow => manual` and a
   `Range` header when a `.part` file is present.
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

-define(PROGRESS_INTERVAL_MS, 100).

-record(stream, {
    ref :: livery_client:stream_ref(),
    io :: file:io_device(),
    ctx :: term(),
    bytes :: non_neg_integer(),
    total :: non_neg_integer() | undefined,
    timeout :: pos_integer(),
    srv :: pid(),
    self_ref :: pid(),
    last_emit :: integer()
}).

-spec start_link(barrel_inference_server_fetch_resolvers:parsed(), map(), pid()) -> {ok, pid()}.
start_link(Parsed, Opts, SrvPid) when is_map(Opts), is_pid(SrvPid) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Parsed, Opts, SrvPid])}.

-spec init(barrel_inference_server_fetch_resolvers:parsed(), map(), pid()) -> no_return().
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
    {ok, Root} = barrel_inference_server_fetch:cache_root(),
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
    case barrel_inference_server_fetch_resolvers:resolve(Parsed) of
        {ok, R} -> {ok, Parsed, hf_attach_etag(R, Opts)};
        E -> E
    end;
resolve({ollama, _, _, _} = Parsed, Opts) ->
    Fetch = fun(URL, Hdrs) -> http_get_body(URL, Hdrs, Opts) end,
    case barrel_inference_server_fetch_resolvers:resolve(Parsed, Fetch) of
        {ok, R} -> {ok, Parsed, R};
        E -> E
    end;
resolve(Parsed, _Opts) ->
    case barrel_inference_server_fetch_resolvers:resolve(Parsed) of
        {ok, R} -> {ok, Parsed, R};
        E -> E
    end.

resolve_hf_no_path(Org, Repo, Rev, Opts) ->
    Fetch = fun(URL, Hdrs) -> http_get_body(URL, Hdrs, Opts) end,
    case barrel_inference_server_fetch_resolvers:hf_list_siblings(Org, Repo, Rev, Fetch) of
        {ok, Files} -> resolve_hf_pick(Org, Repo, Rev, Files, Opts);
        {error, _} = E -> E
    end.

resolve_hf_pick(Org, Repo, Rev, Files, Opts) ->
    case barrel_inference_server_fetch_resolvers:hf_pick_gguf(Files) of
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
            %% livery push-stream surfaces unfollowed redirects (e.g.
            %% cross-host); retry with the new location.
            Resolved1 = Resolved#{url => NewURL},
            stream_with_redirects(Parsed, Resolved1, Opts, SrvPid, Self, Root, N - 1);
        Other ->
            Other
    end.

open_stream(Parsed, Resolved, Opts, SrvPid, Self, Root) ->
    SpecHash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
    Tmp = filename:join([Root, "tmp", <<SpecHash/binary, ".part">>]),
    {Offset, HashCtx0} = resume_state(Tmp),
    URL = maps:get(url, Resolved),
    Hdrs = build_headers(maps:get(headers, Resolved), Offset),
    Timeout = maps:get(timeout, Opts, 120_000),
    Client = stream_client(Timeout),
    ReqOpts = #{
        headers => Hdrs,
        timeout => Timeout,
        stream => true,
        stream_to => self(),
        flow => manual
    },
    case livery_client:request(Client, get, URL, ReqOpts) of
        {ok, #{body := {push, StreamRef}}} ->
            stream_recv(
                StreamRef,
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

%% A livery_client wrapped around the hackney adapter. We force HTTP/1.1
%% ALPN because async streaming over HTTP/2 wedges silently on this
%% hackney version (no body messages arrive). Sync HEAD / manifest GET
%% reuse the same client.
stream_client(Timeout) ->
    livery_client:new(#{
        adapter_opts => #{
            hackney => [
                {follow_redirect, true},
                {max_redirect, 5},
                {connect_timeout, Timeout},
                {protocols, [http1]}
            ]
        }
    }).

sync_client(Timeout) ->
    livery_client:new(#{
        adapter_opts => #{
            hackney => [
                {follow_redirect, true},
                {max_redirect, 5},
                {connect_timeout, Timeout}
            ]
        }
    }).

-record(rcv, {
    client :: livery_client:stream_ref(),
    tmp :: file:filename_all(),
    offset :: non_neg_integer(),
    hash :: term(),
    timeout :: pos_integer(),
    srv :: pid(),
    self_ref :: pid(),
    resolved :: barrel_inference_server_fetch_resolvers:resolved(),
    parsed :: barrel_inference_server_fetch_resolvers:parsed(),
    root :: file:filename_all()
}).

stream_recv(StreamRef, Tmp, Offset, HashCtx0, Timeout, SrvPid, Self, Resolved, Parsed, Root) ->
    R = #rcv{
        client = StreamRef,
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
    case wait_status(StreamRef, Timeout) of
        {ok, Status, RespHdrs} when Status =:= 200; Status =:= 206 ->
            handle_ok_status(Status, RespHdrs, R);
        {ok, Status, _RespHdrs} ->
            stop_stream(StreamRef),
            {error, {http_status, Status}};
        {redirect, _} = Redir ->
            stop_stream(StreamRef),
            Redir;
        {error, _} = E ->
            E
    end.

handle_ok_status(Status, RespHdrs, R) ->
    {RealOffset, HashCtx} = resume_for_status(Status, R#rcv.offset, R#rcv.hash),
    {ok, IO} = file:open(R#rcv.tmp, file_mode(RealOffset)),
    State = init_stream(R, IO, HashCtx, RealOffset, Status, RespHdrs),
    ok = emit_progress(State),
    consume(advance(State), R#rcv.tmp, R#rcv.resolved, R#rcv.parsed, R#rcv.root).

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
            _ = try_close(FinalState#stream.io),
            {error, Reason}
    end.

try_close(IO) ->
    try
        file:close(IO)
    catch
        _:_ -> ok
    end.

%% Advance the manual-flow push stream by one message slot.
advance(#stream{ref = Ref} = S) ->
    ok = livery_client:stream_next(Ref),
    S.

stream_loop(#stream{ref = Ref, timeout = Timeout} = S) ->
    receive
        {livery_response, Ref, {chunk, Bin}} when is_binary(Bin) -> on_chunk(Bin, S);
        {livery_response, Ref, done} -> on_done(S);
        {livery_response, Ref, {error, Reason}} -> {error, Reason, S};
        _Other -> stream_loop(S)
    after Timeout ->
        stop_stream(Ref),
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
%% Status / header reception (push stream)
%% =============================================================================

%% Push streaming delivers status + headers in a single first message.
%% A redirect hackney does not follow (e.g. cross-host with auth) is
%% surfaced as `{error, {redirect, Location}}` from the livery relay; the
%% caller retries with the new URL.
wait_status(Ref, Timeout) ->
    receive
        {livery_response, Ref, {status, Status, Hdrs}} ->
            {ok, Status, Hdrs};
        {livery_response, Ref, {error, {redirect, Loc}}} ->
            {redirect, Loc};
        {livery_response, Ref, {error, Reason}} ->
            {error, Reason}
    after Timeout ->
        stop_stream(Ref),
        {error, status_timeout}
    end.

stop_stream(Ref) ->
    _ = livery_client:stop_stream(Ref),
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
    SpecHash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
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
    end.

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
    Timeout = maps:get(timeout, Opts, 15000),
    Client = sync_client(Timeout),
    case livery_client:request(Client, head, URL, #{headers => Hdrs, timeout => Timeout}) of
        {ok, Resp} ->
            {ok, livery_client:status(Resp), livery_client:headers(Resp)};
        {error, _} = E ->
            E
    end.

http_get_body(URL, Hdrs, Opts) ->
    Timeout = maps:get(timeout, Opts, 15000),
    Client = sync_client(Timeout),
    case livery_client:request(Client, get, URL, #{headers => Hdrs, timeout => Timeout}) of
        {ok, Resp} ->
            {full, Body} = livery_client:body(Resp),
            {ok, livery_client:status(Resp), livery_client:headers(Resp), Body};
        {error, _} = E ->
            E
    end.
