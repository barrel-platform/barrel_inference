# livery 0.4.x — forward `max_body_size` to h1's parser

## Problem

`h1`'s parser enforces its own body-size cap via the
`max_body_size` parser option, defaulting to `?H1_MAX_BODY_SIZE`
(8 MiB) in `_build/default/lib/h1/include/h1.hrl`. When the
parser sees a body chunk that pushes cumulative bytes past
that cap (`h1_parse_erl:enforce_body_size/2`), it returns
`{error, body_too_large}` and the connection driver resets
the stream (`{client_reset, {shutdown, body_too_large}}`).

The reset fires at the parser layer, BEFORE livery's listener
`max_body` cap (`livery_body:account/3`) and BEFORE the
early-response drain path added in livery 0.4.0. So any body
> 8 MiB:

1. Aborts mid-upload with a stream reset.
2. The client (hackney here) sees `{error, closed}`.
3. The application's `livery_resp:json(413, ...)` early-response
   never reaches the client because the drain logic was never
   armed.

`livery_h1:build_h1_opts/3` does not pass `max_body_size` to
`h1:start_server/2`; its `copy_keys` list (lines 313-328)
copies `ip, inet6, cert, key, cacerts, ssl_opts, acceptors,
handshake_timeout, idle_timeout, request_timeout,
early_response_drain, lingering_timeout,
max_keepalive_requests`. So even passing `max_body_size` in
the livery listener opts has no effect downstream.

## Reproduction

Against barrel_inference_server with livery 0.4.4 + h1 0.7.0:

```
init_per_suite:
  application:set_env(barrel_inference_server, max_request_body_bytes,
                      12 * 1024 * 1024).

POST /v1/messages, Content-Length 9437184 (9 MiB of "x"), expecting
the handler to read the body and 400 on JSON decode.

Observed: hackney returns `{error, closed}`. Server log shows the
413 access-log NOTICE was queued but never delivered. Debug print
inside `barrel_inference_server_body:read/2`:

  [DEBUG body] Max=12582912 err={client_reset,{shutdown,body_too_large}}
```

The application asked for a 12 MiB cap; h1's parser enforced its
own 8 MiB default.

The three smoke cases this blocks
(`apps/barrel_inference_server/test/barrel_inference_server_smoke_SUITE.erl`)
are currently re-skipped with `{skip, livery_h1_max_body_size_not_forwarded}`:

- `accepts_body_above_cowboy_default_length/1` (9 MiB body, expects 400)
- `messages_413_returns_request_too_large_type/1` (13 MiB body, expects 413)
- `responses_413_returns_request_too_large_type/1` (13 MiB body, expects 413)

## What we want

Two minimal options:

a. **Default h1's parser cap to `infinity`** when livery owns the
   body-size policy via its own `max_body` listener option +
   `livery_body:account/3`. Livery's check fires at the same layer,
   keeps the stream alive, and feeds the drain. The parser cap is
   then redundant defense-in-depth that fires too early and the
   wrong way.

b. **Forward `max_body_size`** through `livery_h1:build_h1_opts/3`'s
   `copy_keys` list (and document it on `listener_opts()`), so
   applications can set:

   ```erlang
   #{ http => #{ port => 8080,
                 max_body => 12 * 1024 * 1024,
                 max_body_size => infinity } }
   ```

   and rely on livery's own cap for the drain-aware behaviour.

Option (a) is the right default: applications that wire
`max_body` are explicitly opting into livery's per-listener
size policy + drain semantics, and the parser cap silently
overriding that with 8 MiB is the surprise.

## Suggested patch shape (option a)

In `_build/default/lib/livery/src/livery_h1.erl:build_h1_opts/3`,
add `max_body_size => infinity` to the base h1 options unless the
caller already supplied one:

```erlang
build_h1_opts(Opts, Stack, Handler) ->
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    Transport = maps:get(transport, Opts, tcp),
    Base = #{
        transport => Transport,
        handler => make_handler_fun(
            Stack, Handler, MaxBody, maps:get(config, Opts, undefined), Transport
        ),
        max_body_size => maps:get(max_body_size, Opts, infinity)
    },
    copy_keys([..., max_body_size], Opts, Base).
```

Same shape on h2/h3 for parity.

## What we can offer

- Patch validation: un-skip the three smoke cases above against
  a livery branch + bump.
- A regression test in livery's own suite: send a 9 MiB POST to a
  handler that returns `{full, 413, [], <<>>}` and assert the client
  reads the 413 status (not `{error, closed}`).
