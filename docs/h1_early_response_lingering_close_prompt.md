# h1 0.6.2 — early-response races socket close on unread inbound body

## Problem

`h1:respond/5` (or `h1:send_data/_,_, EndStream=true`) with `close_after => true` on a stream whose request body has NOT been fully read sends the response and then immediately tears the socket down via lingering close. On the wire the FIN can land at the client before the client's userspace has read the response bytes, under any of: large remaining inbound body, slow link, busy receiver, small kernel recv buffer. Result: the client sees `{error, socket_closed_remotely}` / `Connection reset by peer` instead of the response we committed (typically a 4xx like 413).

This is the residual after the 0.6.2 patch that added `close_after`: `Connection: close` is correctly advertised and the response is written, but lingering close does not wait for the peer's FIN, and the application has no API to bound that wait.

## What we want

One of:

a. **Bounded inbound drain on early response.** When the response is committed and `inbound_state =/= end_stream`, h1 should `recv` and discard up to a configured `{max_bytes, max_ms}` budget on the inbound side before closing, so the client's send buffer drains and its receive side gets a chance to consume the response. Configurable per-listener (e.g. `early_response_drain => {16#400000, 5000}`); zero disables and restores current behaviour.

b. **Graceful close waiting on peer FIN.** Alternatively, after writing the response, h1 does `shutdown(write)`, then `recv` until peer FIN or `max_ms`, then close. Same idea, different mechanism.

Either way: a public knob on the API (`h1:respond/6` with options map) or on the listener config.

## Reproduction (standalone, no livery / no application code)

Drop into `test/h1_early_response_SUITE.erl` (or eunit equivalent). It uses raw `gen_tcp` on both sides so it does not depend on any HTTP client.

The server arm wires up an h1 listener whose handler answers 413 on the first body byte. Adapt the two TODO functions to h1's actual listener-start and respond APIs; the test logic itself is framework-agnostic.

```erlang
-module(h1_early_response_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([early_413_delivered_under_large_body/1]).

-define(BODY_MIB, 16).
-define(ITERATIONS, 20).

all() -> [early_413_delivered_under_large_body].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    %% TODO: replace with h1's listener-start API.
    %% Handler: on first body byte, reply 413 with close_after => true,
    %% do NOT drain the rest of the body.
    {ok, ListenerPid, Port} = start_h1_413_listener(),
    [{listener, ListenerPid}, {port, Port} | Config].

end_per_suite(Config) ->
    ok = stop_h1_413_listener(?config(listener, Config)),
    ok.

early_413_delivered_under_large_body(Config) ->
    Port = ?config(port, Config),
    Body = crypto:strong_rand_bytes(?BODY_MIB * 1024 * 1024),
    Results = [run_one(Port, Body) || _ <- lists:seq(1, ?ITERATIONS)],
    Failures = [R || R <- Results, R =/= {ok, 413}],
    case Failures of
        [] -> ok;
        _  ->
            ct:fail({"early 413 not delivered reliably",
                     {failures, length(Failures), of_, ?ITERATIONS},
                     {sample, lists:sublist(Failures, 5)}})
    end.

run_one(Port, Body) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port,
                              [binary, {active, false}, {packet, 0},
                               {nodelay, true}, {send_timeout, 5000}]),
    Hdr = iolist_to_binary([
        <<"POST /upload HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Content-Type: application/octet-stream\r\n">>,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>,
        <<"Connection: close\r\n\r\n">>
    ]),
    ok = gen_tcp:send(S, Hdr),
    %% Send body in chunks so we are still mid-upload when the server replies.
    _ = send_chunks(S, chunk(Body, 64 * 1024)),
    read_status_or_reset(S).

send_chunks(_S, []) -> ok;
send_chunks(S, [C | Rest]) ->
    case gen_tcp:send(S, C) of
        ok ->
            %% Small inter-chunk gap exposes the race on fast loopbacks.
            timer:sleep(1),
            send_chunks(S, Rest);
        {error, _} ->
            send_failed
    end.

read_status_or_reset(S) ->
    inet:setopts(S, [{active, false}]),
    case gen_tcp:recv(S, 0, 5000) of
        {ok, <<"HTTP/1.1 ", Code:3/binary, _/binary>>} ->
            gen_tcp:close(S),
            {ok, binary_to_integer(Code)};
        {ok, Other} ->
            gen_tcp:close(S),
            {unexpected, Other};
        {error, Reason} ->
            gen_tcp:close(S),
            {error, Reason}
    end.

chunk(<<>>, _N) -> [];
chunk(B, N) when byte_size(B) =< N -> [B];
chunk(<<H:N/binary, T/binary>>, N) -> [H | chunk(T, N)].

%% --- adapt these two ---------------------------------------------------
start_h1_413_listener() ->
    %% Use h1's public listener API. Handler shape (pseudocode):
    %%   handle(Conn, StreamId, _Req) ->
    %%       %% read at most one chunk, then early-respond
    %%       _ = h1:read_body(Conn, StreamId, #{length => 1024, period => 100}),
    %%       Body = <<"{\"error\":\"request_too_large\"}">>,
    %%       h1:respond(Conn, StreamId, 413,
    %%                  [{<<"content-type">>, <<"application/json">>},
    %%                   {<<"connection">>, <<"close">>}],
    %%                  Body,
    %%                  #{close_after => true}),
    %%       ok.
    erlang:error({todo, replace_with_h1_listener_start}).

stop_h1_413_listener(_Pid) ->
    erlang:error({todo, replace_with_h1_listener_stop}).
```

Expected (after the fix): all 20 iterations return `{ok, 413}`.

Observed on 0.6.2: a non-trivial fraction return `{error, closed}` / `{error, socket_closed_remotely}` / `{unexpected, _}`, depending on RTT, body size, and chunk pacing. Increasing `?BODY_MIB` raises the failure rate.

## Downstream context (for triage, not required to reproduce)

The barrel_inference_server smoke suite has three currently-skipped CT cases tagged `{skip, livery_h1_response_after_lingering_close}` that fail intermittently against h1 0.6.2 via livery 0.3.x. They are the application-level mirror of the standalone case above: `POST /v1/messages`, `/v1/chat/completions`, `/v1/responses` with a 13 MiB body against a 12 MiB cap. Once h1 ships either (a) or (b) and we bump, those three un-skip and stay green.

## What we can offer

- The reproduction harness above (ready to land once the listener API stubs are filled in).
- Patch validation against the full barrel_inference CT suite once the fix is on a branch.
- Co-author the README note on early-response semantics if useful.
