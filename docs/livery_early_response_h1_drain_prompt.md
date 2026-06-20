# livery 0.3.x — propagate h1's early-response drain to handler `{full, _, _, _}` responses

## Problem

When a livery handler returns `{full, Status, Headers, Body}` (e.g. via `livery_resp:json/2,3`) while the request body has not been fully read, the response goes out on the underlying h1 stream and the connection is then closed via h1's lingering-close path. With large in-flight inbound bodies, the close can land at the client before the client's userspace has read the response bytes — the client sees `{error, socket_closed_remotely}` / `Connection reset by peer` instead of the 4xx we committed (typically a 413).

This is the livery-facing mirror of the h1 0.6.2 follow-up. h1 now (or will, depending on which option ships) expose either:

a. a bounded inbound-drain knob (`early_response_drain => {max_bytes, max_ms}`), or
b. a graceful-close-waiting-on-peer-FIN option,

on its respond/send_data API. Livery needs to drive that from the framework side so handlers do not have to know about h1 internals.

## What we want

When a livery handler returns `{full, _, _, _}` (or `{json, _, _, _}` / `{text, _, _, _}` / any non-streaming decision) AND the request body is not at `end_stream`, livery should automatically engage h1's new drain/graceful-close path. No handler change required. Two layers:

1. **Default-on auto-detect.** In the response-emit path inside `livery_resp` (or wherever the decision is converted to h1 calls), branch on the inbound-state of the underlying h1 stream:
   - `end_stream` → current behaviour (close immediately, no drain).
   - anything else → call h1's new API with `early_response_drain => Default` (e.g. `{4 MiB, 5000 ms}`) and `close_after => true`. Adopt h1's defaults if they ship sensible ones.
2. **Per-handler override.** Expose the knob via `livery_resp:options/1` or a new field on the response map, e.g.

   ```erlang
   livery_resp:json(413, Headers, Body, #{early_response_drain => {16#400000, 5000}}).
   ```

   Setting `early_response_drain => 0` (or `none`) opts out and restores current behaviour for that specific response.

Same treatment for streaming decisions (`{sse, _, _, _}` / `{ndjson, _, _, _}` / `{stream, _, _, _}`) when they finish without the body having been read; the producer-end emit-and-close path is the same shape.

## Reproduction

The barrel_inference_server smoke suite has three currently-skipped CT cases that exercise this end-to-end against livery 0.3.x + h1 0.6.2 + hackney 4.4.0:

- `messages_413_returns_request_too_large_type/1`
- `chat_413_returns_request_too_large_type/1`
- `responses_413_returns_request_too_large_type/1`

All three are tagged `{skip, livery_h1_response_after_lingering_close}` in
`apps/barrel_inference_server/test/barrel_inference_server_smoke_SUITE.erl`.

Shape: client POSTs a 13 MiB body against a 12 MiB cap; handler reads enough to hit the cap, returns `livery_resp:json(413, json:encode(error_body(request_too_large, 413)))`; client (hackney) often observes `socket_closed_remotely` before reading the 413.

A standalone reproducer that does not depend on barrel: write a livery handler whose `init/2` immediately returns `{full, 413, [], <<"too big">>}` without reading the request body, point hackney at it with a multi-MiB POST, observe the failure rate climb with body size and ease with body size.

Minimal sketch (adapt to livery's actual handler API):

```erlang
-module(livery_early_response_repro).
-export([init/2]).

init(_Req, State) ->
    %% Do NOT read the body. Return a non-streaming response immediately.
    {ok, livery_resp:json(413, [], <<"{\"error\":\"too_big\"}">>), State}.
```

Client side: same `gen_tcp`-based loop as the h1 prompt's standalone reproducer, but pointed at livery's listener instead of an h1 listener. Expected after the fix: all iterations return 413; observed today: a fraction return `{error, closed}` / `{error, socket_closed_remotely}`.

## Suggested patch shape

- New optional field on the response record / decision tuple: `early_response_drain :: {non_neg_integer(), non_neg_integer()} | none | default`, defaulting to `default`.
- In the emit path, compute the effective drain budget:
  - `none` → pass `close_after => true` only, no drain (current behaviour).
  - `default` → pass h1's app-configured default (or livery's own, e.g. `{4 MiB, 5000 ms}`).
  - explicit `{Bytes, Ms}` → pass through.
- Wire it into the call to `h1:respond/6` (or whichever shape h1 lands on).
- Document the default in livery's README under "Early-response semantics", aimed at handlers that hit body caps before draining.

## Downstream impact

Once livery exposes this and bumps h1, barrel_inference will:

1. Bump `livery` in `apps/barrel_inference_server/rebar.config` and `apps/barrel_inference_cli/rebar.config`.
2. Bump h1 (via livery's transitive constraint).
3. Un-skip the three smoke cases above and verify they stay green over a few hundred iterations of `rebar3 ct --suite=barrel_inference_server_smoke_SUITE --case=messages_413_returns_request_too_large_type`.

## What we can offer

- The three CT cases above as a real-world soak test once a livery branch is up.
- A standalone livery-only reproducer if useful for upstream's own CT suite.
- Patch validation against the full barrel_inference suite.

## Coordination note

This depends on the h1 follow-up — see the companion prompt
`docs/h1_early_response_lingering_close_prompt.md`. If h1 lands option (a) (bounded inbound drain), the livery API surface above maps 1:1. If h1 lands option (b) (graceful close on peer FIN), the per-response knob shrinks to a single `early_response_grace_ms` integer; everything else is the same.
