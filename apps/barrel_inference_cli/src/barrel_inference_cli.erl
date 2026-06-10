%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_cli).
-moduledoc """
Command-line front end for Barrel Inference.

Built as a `rebar3 escriptize` artefact at `_build/default/bin/barrel-inference`.
`serve` launches the release daemon; every other subcommand speaks to a
running daemon over HTTP (livery_client). Nothing here loads inference modules
directly.

Subcommands:

```
barrel-inference serve                       run the API server in-process
barrel-inference pull <name>                 pull a model into the registry
barrel-inference run <name> [prompt...]      stream a single chat completion
barrel-inference ps                          list currently-loaded models
barrel-inference rm <name>                   remove a manifest
barrel-inference version                     print the server version
barrel-inference help                        this message
```

The `cluster` namespace is reserved: `barrel-inference cluster <subcmd>`
delegates to `barrel_inference_cluster_cli` when that app is present.

Base URL: `BARREL_INFERENCE_HOST` env var, default `http://127.0.0.1:8080`.
""".

-export([main/1]).

-define(DEFAULT_HOST, "http://127.0.0.1:8080").

%% =============================================================================
%% Entry
%% =============================================================================

main([]) ->
    usage(),
    halt(1);
main(["help" | _]) ->
    usage();
main(["-h" | _]) ->
    usage();
main(["--help" | _]) ->
    usage();
main(["serve" | Rest]) ->
    cmd_serve(Rest);
main(["cluster" | Rest]) ->
    %% Reserved namespace. The cluster follow-up ships
    %% barrel_inference_cluster_cli:run/1 in apps/barrel_inference_cluster;
    %% this clause wires it up with no further change here.
    delegate(barrel_inference_cluster_cli, Rest);
main(Args) ->
    {ok, _} = application:ensure_all_started(livery),
    Base = base_url(),
    dispatch(Base, Args).

%% Delegate a reserved sub-namespace to its own CLI module when the
%% owning app is part of this build.
delegate(Mod, Args) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            Mod:run(Args);
        {error, _} ->
            io:put_chars(
                io_lib:format(
                    "subcommand requires ~s, which is not part of this build~n",
                    [Mod]
                )
            ),
            halt(2)
    end.

dispatch(Base, ["pull", Name | _]) ->
    cmd_pull(Base, Name);
dispatch(Base, ["list" | _]) ->
    cmd_list(Base);
dispatch(Base, ["ls" | _]) ->
    cmd_list(Base);
dispatch(Base, ["show", Name | _]) ->
    cmd_show(Base, Name);
dispatch(Base, ["rm", Name | _]) ->
    cmd_rm(Base, Name);
dispatch(Base, ["delete", Name | _]) ->
    cmd_rm(Base, Name);
dispatch(Base, ["copy", Src, Dst | _]) ->
    cmd_copy(Base, Src, Dst);
dispatch(Base, ["cp", Src, Dst | _]) ->
    cmd_copy(Base, Src, Dst);
dispatch(Base, ["search", Q | _]) ->
    cmd_search(Base, Q);
dispatch(Base, ["run", Name | Rest]) ->
    cmd_run(Base, Name, prompt_from(Rest));
dispatch(Base, ["ps" | _]) ->
    cmd_ps(Base);
dispatch(Base, ["version" | _]) ->
    cmd_version(Base);
dispatch(Base, ["--version" | _]) ->
    cmd_version(Base);
dispatch(Base, ["-v" | _]) ->
    cmd_version(Base);
dispatch(Base, ["unload", Name | _]) ->
    cmd_unload(Base, Name);
dispatch(Base, ["embed", Name | Rest]) ->
    cmd_embed(Base, Name, prompt_from(Rest));
dispatch(_, _) ->
    usage(),
    halt(2).

%% =============================================================================
%% Subcommands
%% =============================================================================

%% `serve`: launch the release's barrel_inference_server start script
%% (foreground by default) and relay its output. Running the release
%% rather than booting in-process means the NIF and beams load from disk;
%% a bare escript cannot load the NIF from inside its archive.
cmd_serve(Args) ->
    case release_daemon() of
        {ok, Daemon} ->
            SubArgs =
                case Args of
                    [] -> ["foreground"];
                    _ -> Args
                end,
            Port = open_port(
                {spawn_executable, Daemon},
                [{args, SubArgs}, exit_status, stderr_to_stdout, binary]
            ),
            relay_daemon(Port);
        {error, not_found} ->
            io:put_chars(
                "serve launches the release daemon, but the "
                "barrel_inference_server start script was not found next to "
                "this binary or on PATH. Run serve from an installed release.\n"
            ),
            halt(1)
    end.

relay_daemon(Port) ->
    receive
        {Port, {data, Bytes}} ->
            io:put_chars(Bytes),
            relay_daemon(Port);
        {Port, {exit_status, Status}} ->
            halt(Status)
    end.

%% Locate the barrel_inference_server release start script: next to this
%% escript (the release ships both in bin/), else on PATH.
release_daemon() ->
    Sibling = filename:join(
        filename:dirname(filename:absname(escript:script_name())),
        "barrel_inference_server"
    ),
    case filelib:is_regular(Sibling) of
        true ->
            {ok, Sibling};
        false ->
            case os:find_executable("barrel_inference_server") of
                false -> {error, not_found};
                Path -> {ok, Path}
            end
    end.

cmd_pull(Base, Name) ->
    Body = json:encode(#{<<"name">> => list_to_binary(Name), <<"stream">> => true}),
    case stream_post(Base ++ "/api/pull", Body) of
        ok -> ok;
        {error, _} = E -> die("pull failed", E)
    end.

cmd_list(Base) ->
    case json_get(Base ++ "/api/tags") of
        {ok, #{<<"models">> := Models}} ->
            print_table(Models);
        {error, Reason} ->
            die("list failed", Reason)
    end.

cmd_show(Base, Name) ->
    Body = json:encode(#{<<"name">> => list_to_binary(Name)}),
    case json_post(Base ++ "/api/show", Body) of
        {ok, M} ->
            io:put_chars(
                io_lib:format("~ts~n", [pretty(M)])
            );
        {error, Reason} ->
            die("show failed", Reason)
    end.

cmd_rm(Base, Name) ->
    Body = json:encode(#{<<"name">> => list_to_binary(Name)}),
    case json_request(delete, Base ++ "/api/delete", Body) of
        {ok, _Code, _Body} ->
            io:put_chars(io_lib:format("removed ~s~n", [Name]));
        {error, Reason} ->
            die("rm failed", Reason)
    end.

cmd_copy(Base, Src, Dst) ->
    Body = json:encode(#{
        <<"source">> => list_to_binary(Src),
        <<"destination">> => list_to_binary(Dst)
    }),
    case json_request(post, Base ++ "/api/copy", Body) of
        {ok, _, _} ->
            io:put_chars(io_lib:format("copied ~s -> ~s~n", [Src, Dst]));
        {error, Reason} ->
            die("copy failed", Reason)
    end.

cmd_search(Base, Query) ->
    Body = json:encode(#{<<"query">> => list_to_binary(Query)}),
    case json_post(Base ++ "/api/search", Body) of
        {ok, #{<<"hits">> := Hits}} ->
            print_search_hits(Hits);
        {error, Reason} ->
            die("search failed", Reason)
    end.

cmd_run(Base, Name, Prompt) ->
    Body = json:encode(#{
        <<"model">> => list_to_binary(Name),
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => Prompt
            }
        ],
        <<"stream">> => true
    }),
    case stream_post_sse(Base ++ "/v1/chat/completions", Body) of
        ok -> ok;
        {error, Reason} -> die("run failed", Reason)
    end.

cmd_ps(Base) ->
    case json_get(Base ++ "/api/ps") of
        {ok, #{<<"models">> := []}} ->
            io:put_chars("(no loaded models)\n");
        {ok, #{<<"models">> := Models}} ->
            print_ps_table(Models);
        {error, Reason} ->
            die("ps failed", Reason)
    end.

cmd_version(Base) ->
    case json_get(Base ++ "/api/version") of
        {ok, #{<<"version">> := V}} ->
            io:put_chars(io_lib:format("~ts~n", [V]));
        {error, Reason} ->
            die("version failed", Reason)
    end.

cmd_unload(Base, Name) ->
    %% Ollama convention: empty prompt + keep_alive 0 -> unload now.
    Body = json:encode(#{
        <<"model">> => list_to_binary(Name),
        <<"prompt">> => <<>>,
        <<"keep_alive">> => 0,
        <<"stream">> => false
    }),
    case json_post(Base ++ "/api/generate", Body) of
        {ok, #{<<"done_reason">> := <<"unload">>}} ->
            io:put_chars(io_lib:format("unloaded ~s~n", [Name]));
        {ok, _Other} ->
            io:put_chars(io_lib:format("~s was not loaded~n", [Name]));
        {error, Reason} ->
            die("unload failed", Reason)
    end.

cmd_embed(Base, Name, Text) ->
    Body = json:encode(#{
        <<"model">> => list_to_binary(Name),
        <<"input">> => Text
    }),
    case json_post(Base ++ "/api/embed", Body) of
        {ok, #{<<"embeddings">> := [V | _]}} ->
            io:put_chars(io_lib:format("dim=~B~n", [length(V)])),
            io:put_chars(io_lib:format("~p~n", [V]));
        {error, Reason} ->
            die("embed failed", Reason)
    end.

%% =============================================================================
%% Output helpers
%% =============================================================================

print_table([]) ->
    io:put_chars("(no models)\n");
print_table(Models) ->
    Rows = [row(M) || M <- Models],
    Widths = column_widths(Rows),
    io:put_chars([format_row(Widths, [<<"NAME">>, <<"SIZE">>, <<"QUANT">>, <<"FAMILY">>])]),
    [io:put_chars([format_row(Widths, R)]) || R <- Rows],
    ok.

row(M) ->
    Details = maps:get(<<"details">>, M, #{}),
    [
        maps:get(<<"name">>, M, <<>>),
        human_size(maps:get(<<"size">>, M, 0)),
        nullable(maps:get(<<"quantization_level">>, Details, null)),
        nullable(maps:get(<<"family">>, Details, null))
    ].

format_row(Widths, Cols) ->
    [
        [pad(Col, W), <<"  ">>]
     || {Col, W} <- lists:zip(Cols, Widths)
    ] ++ [<<"\n">>].

column_widths(Rows) ->
    Header = [<<"NAME">>, <<"SIZE">>, <<"QUANT">>, <<"FAMILY">>],
    All = [Header | Rows],
    [lists:max([byte_size(to_bin(C)) || C <- column(N, All)]) || N <- lists:seq(1, 4)].

column(N, Rows) ->
    [lists:nth(N, R) || R <- Rows].

pad(Col, W) ->
    Bin = to_bin(Col),
    Need = W - byte_size(Bin),
    case Need > 0 of
        true -> <<Bin/binary, (binary:copy(<<" ">>, Need))/binary>>;
        false -> Bin
    end.

%% Ollama-style `ps` table: name, size in VRAM, digest stem,
%% expires-at (relative seconds remaining or "never").
print_ps_table(Models) ->
    Header = [<<"NAME">>, <<"SIZE">>, <<"DIGEST">>, <<"UNTIL">>],
    Rows = [ps_row(M) || M <- Models],
    Widths = ps_widths(Header, Rows),
    io:put_chars([format_row(Widths, Header)]),
    [io:put_chars([format_row(Widths, R)]) || R <- Rows],
    ok.

ps_row(M) ->
    [
        nullable(maps:get(<<"name">>, M, <<>>)),
        human_size(maps:get(<<"size">>, M, 0)),
        digest_stem(maps:get(<<"digest">>, M, null)),
        until_label(maps:get(<<"expires_at">>, M, null))
    ].

ps_widths(Header, Rows) ->
    All = [Header | Rows],
    [lists:max([byte_size(to_bin(C)) || C <- column(N, All)]) || N <- lists:seq(1, 4)].

digest_stem(null) ->
    <<"-">>;
digest_stem(<<"sha256:", Rest/binary>>) when byte_size(Rest) >= 12 ->
    binary:part(Rest, 0, 12);
digest_stem(Other) ->
    nullable(Other).

until_label(null) -> <<"never">>;
until_label(<<>>) -> <<"never">>;
until_label(B) when is_binary(B) -> B.

human_size(N) when is_integer(N), N >= 1024 * 1024 * 1024 ->
    iolist_to_binary(io_lib:format("~.2f GB", [N / 1.0e9]));
human_size(N) when is_integer(N), N >= 1024 * 1024 ->
    iolist_to_binary(io_lib:format("~.2f MB", [N / 1.0e6]));
human_size(N) when is_integer(N), N >= 1024 ->
    iolist_to_binary(io_lib:format("~.2f KB", [N / 1.0e3]));
human_size(N) when is_integer(N) ->
    integer_to_binary(N);
human_size(_) ->
    <<"-">>.

nullable(null) -> <<"-">>;
nullable(undefined) -> <<"-">>;
nullable(<<>>) -> <<"-">>;
nullable(B) when is_binary(B) -> B;
nullable(I) when is_integer(I) -> integer_to_binary(I);
nullable(_) -> <<"-">>.

print_search_hits([]) ->
    io:put_chars("(no results)\n");
print_search_hits(Hits) ->
    [
        io:put_chars(
            io_lib:format("~ts  ~ts~n", [
                maps:get(<<"id">>, H, <<>>),
                maps:get(<<"name">>, H, <<>>)
            ])
        )
     || H <- Hits
    ],
    ok.

pretty(M) when is_map(M) ->
    Pairs = [
        io_lib:format("~ts: ~ts~n", [Key, format_value(V)])
     || {Key, V} <- maps:to_list(M)
    ],
    iolist_to_binary(Pairs).

format_value(V) when is_binary(V) -> V;
format_value(V) when is_integer(V) -> integer_to_binary(V);
format_value(V) when is_float(V) -> float_to_binary(V, [{decimals, 4}]);
format_value(true) ->
    <<"true">>;
format_value(false) ->
    <<"false">>;
format_value(null) ->
    <<"null">>;
format_value(M) when is_map(M) ->
    iolist_to_binary([
        <<"{">>,
        lists:join(<<", ">>, [
            io_lib:format("~ts: ~ts", [K, format_value(V)])
         || {K, V} <- maps:to_list(M)
        ]),
        <<"}">>
    ]);
format_value(L) when is_list(L) ->
    iolist_to_binary(io_lib:format("~p", [L])).

%% =============================================================================
%% HTTP helpers
%% =============================================================================

base_url() ->
    case os:getenv("BARREL_INFERENCE_HOST") of
        false -> ?DEFAULT_HOST;
        "" -> ?DEFAULT_HOST;
        S -> S
    end.

json_get(URL) ->
    case livery_client:get(client(), to_bin(URL)) of
        {ok, Resp} ->
            {full, Body} = livery_client:body(Resp),
            case livery_client:status(Resp) of
                200 -> {ok, json:decode(Body)};
                Code -> {error, {http, Code, Body}}
            end;
        {error, _} = E ->
            E
    end.

json_post(URL, Body) ->
    json_request(post, URL, Body).

json_request(Method, URL, Body) ->
    Headers = [{<<"content-type">>, <<"application/json">>}],
    Opts = #{headers => Headers, body => {full, Body}},
    case livery_client:request(client(), Method, to_bin(URL), Opts) of
        {ok, Resp} ->
            {full, RawBody} = livery_client:body(Resp),
            decode_json_response(livery_client:status(Resp), RawBody);
        {error, _} = E ->
            E
    end.

decode_json_response(Code, <<>>) when Code >= 200, Code < 300 ->
    {ok, Code, #{}};
decode_json_response(Code, RawBody) when Code >= 200, Code < 300 ->
    {ok, json:decode(RawBody)};
decode_json_response(Code, RawBody) ->
    {error, {http, Code, RawBody}}.

%% Shared client; no per-call layers (each subcommand is short-lived).
client() ->
    livery_client:new(#{}).

%% Streaming POST that prints each NDJSON status line as it arrives.
%% livery_client push-stream: status + chunks delivered as
%% `{livery_response, Ref, _}` messages on this process's mailbox.
stream_post(URL, Body) ->
    Headers = [{<<"content-type">>, <<"application/json">>}],
    Opts = #{
        headers => Headers,
        body => {full, Body},
        stream => true,
        stream_to => self()
    },
    case livery_client:request(client(), post, to_bin(URL), Opts) of
        {ok, #{body := {push, Ref}}} ->
            stream_recv_ndjson(Ref, <<>>, progress_state());
        {error, _} = E ->
            E
    end.

stream_recv_ndjson(Ref, Buf, State) ->
    receive
        {livery_response, Ref, {status, Code, _Hdrs}} when Code >= 400 ->
            _ = finalize_progress(State),
            drain_error(Ref, Code, <<>>);
        {livery_response, Ref, {status, _Code, _Hdrs}} ->
            stream_recv_ndjson(Ref, Buf, State);
        {livery_response, Ref, done} ->
            {_, State1} = print_ndjson_lines(<<Buf/binary, "\n">>, State),
            _ = finalize_progress(State1),
            %% A 200 stream can still carry an {"error": ...} event
            %% (the status line is sent before the outcome is known),
            %% so surface it as a non-zero exit rather than a clean ok.
            case maps:get(last_error, State1, undefined) of
                undefined -> ok;
                Err -> {error, {pull, Err}}
            end;
        {livery_response, Ref, {error, Reason}} ->
            _ = finalize_progress(State),
            {error, Reason};
        {livery_response, Ref, {chunk, Chunk}} ->
            {Buf1, State1} = print_ndjson_lines(<<Buf/binary, Chunk/binary>>, State),
            stream_recv_ndjson(Ref, Buf1, State1)
    after 600000 ->
        _ = finalize_progress(State),
        _ = livery_client:stop_stream(Ref),
        {error, timeout}
    end.

%% Collect the body of a >= 400 response (push stream) for the error report.
drain_error(Ref, Code, Acc) ->
    receive
        {livery_response, Ref, done} ->
            {error, {http, Code, Acc}};
        {livery_response, Ref, {error, Reason}} ->
            {error, Reason};
        {livery_response, Ref, {chunk, Chunk}} ->
            drain_error(Ref, Code, <<Acc/binary, Chunk/binary>>)
    after 600000 ->
        _ = livery_client:stop_stream(Ref),
        {error, {http, Code, Acc}}
    end.

print_ndjson_lines(Buf, State) ->
    case binary:split(Buf, <<"\n">>) of
        [Last] ->
            {Last, State};
        [Line, Rest] ->
            State1 = print_status_line(Line, State),
            print_ndjson_lines(Rest, State1)
    end.

%% State threaded across NDJSON events so a stream of progress
%% updates on the same `status' overwrites a single line via `\r'
%% (TTY) instead of scrolling N lines. On a status change the
%% previous line is finalised with `\n' and a fresh in-place line
%% starts. In non-TTY mode (pipe / CI / logs) we keep the old
%% line-per-update output so the stream stays parseable.
progress_state() ->
    #{
        last_status => undefined,
        last_error => undefined,
        on_progress_line => false,
        tty => is_tty()
    }.

is_tty() ->
    case io:columns() of
        {ok, _} -> true;
        _ -> false
    end.

print_status_line(<<>>, State) ->
    State;
print_status_line(Line, State) ->
    try json:decode(Line) of
        Decoded -> render_event(Decoded, State)
    catch
        _:_ ->
            State1 = finalize_progress(State),
            io:put_chars([Line, "\n"]),
            State1
    end.

render_event(#{<<"status">> := <<"success">>}, State) ->
    State1 = finalize_progress(State),
    io:put_chars("success\n"),
    State1;
render_event(
    #{<<"status">> := S, <<"completed">> := C, <<"total">> := T},
    State
) when is_integer(T), T > 0, is_integer(C) ->
    progress(S, C, T, State);
render_event(#{<<"status">> := S}, State) ->
    State1 = finalize_progress(State),
    io:put_chars(io_lib:format("~ts~n", [S])),
    State1#{last_status => S};
render_event(#{<<"error">> := E}, State) ->
    State1 = finalize_progress(State),
    io:put_chars(io_lib:format("error: ~ts~n", [E])),
    State1#{last_error => E};
render_event(Other, State) ->
    State1 = finalize_progress(State),
    io:put_chars(io_lib:format("~p~n", [Other])),
    State1.

progress(Status, Completed, Total, State = #{tty := true, last_status := Status}) ->
    io:put_chars([$\r, render_bar(Status, Completed, Total)]),
    State#{on_progress_line => true};
progress(Status, Completed, Total, State) ->
    State1 = finalize_progress(State),
    case maps:get(tty, State1, false) of
        true ->
            io:put_chars(render_bar(Status, Completed, Total)),
            State1#{last_status => Status, on_progress_line => true};
        false ->
            %% Non-TTY: keep the old shape so log scrapers still
            %% see one self-contained line per event.
            io:put_chars(
                io_lib:format("~ts  ~B / ~B~n", [Status, Completed, Total])
            ),
            State1#{last_status => Status, on_progress_line => false}
    end.

finalize_progress(State = #{on_progress_line := true}) ->
    io:put_chars("\n"),
    State#{on_progress_line => false};
finalize_progress(State) ->
    State.

render_bar(Status, Completed, Total) ->
    Pct = (Completed * 100) div Total,
    Filled = Pct div 5,
    Empty = 20 - Filled,
    io_lib:format(
        "~ts: ~3B% [~ts~ts] ~ts / ~ts",
        [
            Status,
            Pct,
            lists:duplicate(Filled, $#),
            lists:duplicate(Empty, $.),
            human_bytes(Completed),
            human_bytes(Total)
        ]
    ).

human_bytes(N) when N < 1024 ->
    io_lib:format("~B B", [N]);
human_bytes(N) when N < 1024 * 1024 ->
    io_lib:format("~.1f KB", [N / 1024]);
human_bytes(N) when N < 1024 * 1024 * 1024 ->
    io_lib:format("~.1f MB", [N / 1024 / 1024]);
human_bytes(N) ->
    io_lib:format("~.2f GB", [N / 1024 / 1024 / 1024]).

%% Streaming POST that prints OpenAI SSE deltas as they arrive (livery
%% push stream).
stream_post_sse(URL, Body) ->
    Headers = [{<<"content-type">>, <<"application/json">>}],
    Opts = #{
        headers => Headers,
        body => {full, Body},
        stream => true,
        stream_to => self()
    },
    case livery_client:request(client(), post, to_bin(URL), Opts) of
        {ok, #{body := {push, Ref}}} ->
            R = stream_recv_sse(Ref, <<>>),
            io:put_chars("\n"),
            R;
        {error, _} = E ->
            E
    end.

stream_recv_sse(Ref, Buf) ->
    receive
        {livery_response, Ref, {status, Code, _Hdrs}} when Code >= 400 ->
            drain_error(Ref, Code, <<>>);
        {livery_response, Ref, {status, _Code, _Hdrs}} ->
            stream_recv_sse(Ref, Buf);
        {livery_response, Ref, done} ->
            ok;
        {livery_response, Ref, {error, Reason}} ->
            {error, Reason};
        {livery_response, Ref, {chunk, Chunk}} ->
            Buf1 = print_sse_events(<<Buf/binary, Chunk/binary>>),
            stream_recv_sse(Ref, Buf1)
    after 600000 ->
        _ = livery_client:stop_stream(Ref),
        {error, timeout}
    end.

print_sse_events(Buf) ->
    case binary:split(Buf, <<"\n">>) of
        [Last] ->
            Last;
        [Line, Rest] ->
            handle_sse_line(strip_cr(Line)),
            print_sse_events(Rest)
    end.

strip_cr(<<>>) ->
    <<>>;
strip_cr(B) ->
    case binary:last(B) =:= $\r of
        true -> binary:part(B, 0, byte_size(B) - 1);
        false -> B
    end.

handle_sse_line(<<>>) ->
    ok;
handle_sse_line(<<": ", _Comment/binary>>) ->
    %% SSE comment (used as a server-side keepalive during model
    %% loading). Ignore in the CLI; the user only cares about content.
    ok;
handle_sse_line(<<"data: [DONE]">>) ->
    ok;
handle_sse_line(<<"data: ", Json/binary>>) ->
    try json:decode(Json) of
        #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := Text}} | _]} ->
            io:put_chars(Text);
        _ ->
            ok
    catch
        _:_ -> ok
    end;
handle_sse_line(_) ->
    ok.

%% =============================================================================
%% Misc
%% =============================================================================

prompt_from([]) ->
    case io:get_chars("", 65536) of
        eof -> <<"">>;
        Bin -> iolist_to_binary(Bin)
    end;
prompt_from(Words) ->
    iolist_to_binary(lists:join(" ", Words)).

usage() ->
    io:put_chars(
        "barrel-inference - command-line client and launcher for Barrel Inference\n"
        "\n"
        "Usage:\n"
        "  barrel-inference serve                    run the API server (release daemon)\n"
        "  barrel-inference pull <name>              pull a model into the registry\n"
        "  barrel-inference run <name> [prompt..]    stream a single chat completion\n"
        "  barrel-inference ps                       list currently-loaded models\n"
        "  barrel-inference rm <name>                remove a manifest\n"
        "  barrel-inference version                  print the server version\n"
        "  barrel-inference list                     list registered models\n"
        "  barrel-inference show <name>              print one manifest\n"
        "  barrel-inference copy <src> <dst>         alias under a new name:tag\n"
        "  barrel-inference search <query>           search HF / Ollama\n"
        "  barrel-inference embed <name> <text..>    compute an embedding vector\n"
        "  barrel-inference unload <name>            evict a model from memory now\n"
        "  barrel-inference help                     this message\n"
        "\n"
        "cluster commands are reserved: barrel-inference cluster <subcmd>\n"
        "Server URL via BARREL_INFERENCE_HOST env (default http://127.0.0.1:8080).\n"
    ).

-spec die(string(), term()) -> no_return().
die(Msg, Detail) ->
    io:put_chars(io_lib:format("~ts: ~p~n", [Msg, Detail])),
    halt(1).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
