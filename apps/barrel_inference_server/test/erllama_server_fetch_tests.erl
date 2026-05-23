%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_fetch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BODY_BYTES, 256 * 1024).

%% =============================================================================
%% Fixture
%% =============================================================================

setup() ->
    %% Don't boot the full erllama_server application; that pulls in
    %% the registry/loader/listener subtree and would conflict with
    %% sibling test modules. We only need the fetch processes plus
    %% hackney + inets. Unlink so test-process exit doesn't take them
    %% down mid-test.
    [application:ensure_all_started(A) || A <- [crypto, ssl, inets, hackney]],
    {ok, FetchSup} = erllama_server_fetch_sup:start_link(),
    unlink(FetchSup),
    {ok, FetchSrv} = erllama_server_fetch_srv:start_link(),
    unlink(FetchSrv),
    Cwd = make_tmp_dir(),
    Cache = filename:join(Cwd, "cache"),
    Doc = filename:join(Cwd, "doc"),
    ok = filelib:ensure_path(Cache),
    ok = filelib:ensure_path(Doc),
    Body = body_fixture(),
    ok = file:write_file(filename:join(Doc, "model.gguf"), Body),
    application:set_env(erllama_server, model_cache_dir, Cache),
    {ok, Pid, Port} = start_httpd(Doc),
    #{
        cwd => Cwd,
        cache => Cache,
        doc => Doc,
        body => Body,
        sha => crypto:hash(sha256, Body),
        httpd => Pid,
        port => Port,
        fetch_sup => FetchSup,
        fetch_srv => FetchSrv
    }.

cleanup(#{cwd := Cwd, httpd := Pid, fetch_sup := FetchSup, fetch_srv := FetchSrv}) ->
    catch inets:stop(httpd, Pid),
    catch gen_server:stop(FetchSrv),
    %% Unlinked supervisor: send a non-link exit signal and wait
    %% briefly for it to terminate. Keep the test process alive.
    catch exit(FetchSup, shutdown),
    application:unset_env(erllama_server, model_cache_dir),
    os:cmd("rm -rf " ++ Cwd),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

fetch_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            ?_test(file_passthrough_returns_existing_path(Ctx)),
            ?_test(file_passthrough_missing_returns_error(Ctx)),
            ?_test(http_round_trip(Ctx)),
            ?_test(http_round_trip_caches(Ctx)),
            ?_test(http_sha256_verify_pass(Ctx)),
            ?_test(http_sha256_mismatch_returns_error(Ctx)),
            ?_test(http_progress_events_arrive(Ctx)),
            ?_test(http_404_returns_error(Ctx)),
            ?_test(async_returns_jobref_and_done_message(Ctx)),
            ?_test(async_status_pending_then_done(Ctx)),
            ?_test(async_await_blocks_until_done(Ctx)),
            ?_test(async_subscribe_extra_pid(Ctx))
        ]
    end}.

file_passthrough_returns_existing_path(#{doc := Doc}) ->
    Path = filename:join(Doc, "model.gguf"),
    ?assertEqual({ok, Path}, erllama_server_fetch:fetch(list_to_binary(Path))).

file_passthrough_missing_returns_error(_Ctx) ->
    ?assertMatch(
        {error, {enoent, _}},
        erllama_server_fetch:fetch(<<"/this/should/not/exist.gguf">>)
    ).

http_round_trip(#{port := Port, body := Body}) ->
    URL = url(Port, "/model.gguf"),
    {ok, Path} = erllama_server_fetch:fetch(URL, #{force => true}),
    {ok, Got} = file:read_file(Path),
    ?assertEqual(Body, Got).

http_round_trip_caches(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    {ok, P1} = erllama_server_fetch:fetch(URL),
    {ok, P2} = erllama_server_fetch:fetch(URL),
    ?assertEqual(P1, P2).

http_sha256_verify_pass(#{port := Port, sha := Sha}) ->
    URL = url(Port, "/model.gguf"),
    Hex = bin_to_hex(Sha),
    ?assertMatch(
        {ok, _}, erllama_server_fetch:fetch(URL, #{force => true, sha256 => Hex})
    ).

http_sha256_mismatch_returns_error(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    Bogus = binary:copy(<<"0">>, 64),
    ?assertMatch(
        {error, {sha256_mismatch, _, _}},
        erllama_server_fetch:fetch(URL, #{force => true, sha256 => Bogus})
    ).

http_progress_events_arrive(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    Self = self(),
    {ok, _} = erllama_server_fetch:fetch(URL, #{force => true, progress => Self}),
    ?assert(received_any_progress(Self, 250)).

http_404_returns_error(#{port := Port}) ->
    URL = url(Port, "/missing.gguf"),
    ?assertMatch(
        {error, {http_status, 404}},
        erllama_server_fetch:fetch(URL, #{force => true})
    ).

%% =============================================================================
%% Async API
%% =============================================================================

async_returns_jobref_and_done_message(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    flush_inbox(),
    {ok, JobRef} = erllama_server_fetch:fetch_async(URL, #{force => true}),
    ?assert(is_binary(JobRef)),
    receive
        {erllama_fetch_done, JobRef, {ok, _Path}} -> ok
    after 5000 ->
        ?assert(false)
    end.

async_status_pending_then_done(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    flush_inbox(),
    {ok, JobRef} = erllama_server_fetch:fetch_async(URL, #{force => true}),
    %% Status should be pending or done; not_found is wrong.
    case erllama_server_fetch:fetch_status(JobRef) of
        {pending, #{phase := _}} -> ok;
        {done, _} -> ok;
        Other -> ?assertEqual({pending, '...'}, Other)
    end,
    receive
        {erllama_fetch_done, JobRef, _} -> ok
    after 5000 -> ?assert(false)
    end,
    ?assertMatch({done, {ok, _}}, erllama_server_fetch:fetch_status(JobRef)).

async_await_blocks_until_done(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    flush_inbox(),
    {ok, JobRef} = erllama_server_fetch:fetch_async(URL, #{force => true}),
    ?assertMatch({ok, _}, erllama_server_fetch:fetch_await(JobRef, 5000)).

async_subscribe_extra_pid(#{port := Port}) ->
    URL = url(Port, "/model.gguf"),
    flush_inbox(),
    Self = self(),
    Watcher = spawn(fun() ->
        receive
            {erllama_fetch_done, _, R} -> Self ! {watcher, R}
        after 5000 -> Self ! {watcher, timeout}
        end
    end),
    {ok, JobRef} = erllama_server_fetch:fetch_async(URL, #{force => true}),
    ok = erllama_server_fetch:fetch_subscribe(JobRef, Watcher),
    receive
        {watcher, {ok, _}} -> ok;
        {watcher, Other} -> ?assert({unexpected, Other} =:= ok)
    after 5000 -> ?assert(false)
    end.

flush_inbox() ->
    receive
        _ -> flush_inbox()
    after 0 -> ok
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

received_any_progress(_Pid, 0) ->
    case
        receive
            {erllama_fetch_progress, _, _, _} -> true
        after 0 -> false
        end
    of
        true -> true;
        false -> false
    end;
received_any_progress(Pid, N) ->
    receive
        {erllama_fetch_progress, _, _, _} -> true
    after 50 -> received_any_progress(Pid, N - 1)
    end.

url(Port, Path) ->
    iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), Path]).

%% Generate a deterministic 256 KiB binary; large enough that hackney
%% delivers it as multiple async chunks but small enough to keep the
%% suite fast.
body_fixture() ->
    Seed = <<0:128>>,
    grow(Seed, ?BODY_BYTES).

grow(Buf, Want) when byte_size(Buf) >= Want ->
    binary:part(Buf, 0, Want);
grow(Buf, Want) ->
    grow(<<Buf/binary, (crypto:hash(sha256, Buf))/binary>>, Want).

bin_to_hex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_fetch_tests_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

%% Minimal local httpd serving a directory tree on a random port.
start_httpd(DocRoot) ->
    application:ensure_all_started(inets),
    {ok, Pid} = inets:start(httpd, [
        {port, 0},
        {server_name, "erllama-test"},
        {server_root, DocRoot},
        {document_root, DocRoot},
        {bind_address, {127, 0, 0, 1}},
        {modules, [mod_get, mod_head]},
        {mime_types, [{"gguf", "application/octet-stream"}]}
    ]),
    Info = httpd:info(Pid),
    Port = proplists:get_value(port, Info),
    {ok, Pid, Port}.
