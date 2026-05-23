# Port fetch + search from `barrel_inference` to `barrel_inference_server`

This is a follow-up task. The `barrel_inference` library (sibling repo at
`../barrel_inference`) currently hosts a model-fetching subsystem
(`barrel_inference:fetch/1,2`, async variants, `barrel_inference:search/1,2`). That
work belongs in `barrel_inference_server`, not in the inference core: it
introduces an HTTP-client dependency (hackney) on the inference
library and is conceptually orthogonal to KV-cache-aware inference.

This document briefs the next agent on how to move it. **Do not
delete from `../barrel_inference` in this task.** A separate follow-up will
prune the fetch + search code from the inference repo once the
ported version is wired in here.

## Current implementation in `../barrel_inference/`

Public façade (in `../barrel_inference/src/barrel_inference.erl`):

```erlang
-export([
    fetch/1, fetch/2,
    fetch_async/1, fetch_async/2,
    fetch_status/1,
    fetch_await/1, fetch_await/2,
    fetch_subscribe/2,
    search/1, search/2
]).
```

Modules (each with a moduledoc explaining intent):

| File | Role |
|---|---|
| `../barrel_inference/src/barrel_inference_fetch.erl` | Public façade. Spec parsing, cache-root resolution, sync/async dispatch. |
| `../barrel_inference/src/barrel_inference_fetch_resolvers.erl` | Pure: parse spec strings into tagged tuples; build per-source URLs/headers; HF siblings list + best-GGUF picker; spec hashing. |
| `../barrel_inference/src/barrel_inference_fetch_srv.erl` | Dedupe registry + progress fan-out + async lifecycle. gen_server. State is keyed by spec hash. Holds a `done` map for 5-min TTL after completion so late `status/1`/`await/2` queries succeed. |
| `../barrel_inference/src/barrel_inference_fetch_sup.erl` | `simple_one_for_one` supervisor for the workers. |
| `../barrel_inference/src/barrel_inference_fetch_worker.erl` | Transient one-shot streaming worker. Async hackney, sha256 streaming digest, resume from `.part`, redirect-following, atomic rename to `blobs/sha256-<hex>.gguf` plus a small `refs/<spec_hash>.ref` text file. |
| `../barrel_inference/src/barrel_inference_search.erl` | Façade for `search/1,2`. Sequential per-source dispatch with an injected sync HTTP fetch fun. |
| `../barrel_inference/src/barrel_inference_search_hf.erl` | HuggingFace `/api/models` query, sorted by downloads, with siblings inline (`full=true`). |
| `../barrel_inference/src/barrel_inference_search_ollama.erl` | Ollama registry catalog (`/v2/_catalog`) substring match. |

Tests (each is offline + uses an injected fetch fun; the integration
suite spins up an `inets` httpd on a random port and exercises the
real hackney path):

| File | Coverage |
|---|---|
| `../barrel_inference/test/barrel_inference_fetch_resolvers_tests.erl` | 28 cases. parse, resolve, HF siblings, GGUF pick, spec hash. |
| `../barrel_inference/test/barrel_inference_fetch_tests.erl` | 12 cases. Local httpd: round-trip, sha256 verify, sha256 mismatch, progress, 404, async + status + await + subscribe. |
| `../barrel_inference/test/barrel_inference_search_tests.erl` | 8 cases. HF + Ollama backends with fake fetch funs. |

Guide: `../barrel_inference/guides/fetching.md` — URL syntax, async usage,
HF auto-pick, search, cache layout, integrity / resume semantics.

## Hackney 4.0.0 quirks the worker handles

These are the bugs / behaviour quirks that the implementation
already accounts for. They will trip you up if you re-derive the
worker from scratch:

1. **HTTP/2 async streaming wedges silently.** `hackney:request/5`
   with `{async, once}` over an HTTPS endpoint that ALPN-negotiates
   HTTP/2 returns `{ok, ConnPid}` and then never sends any
   `{hackney_response, _, _}` messages. Workaround:
   `{protocols, [http1]}` in the request options. See
   `hackney_options/1` in `../barrel_inference/src/barrel_inference_fetch_worker.erl`.
2. **`stream_next/1` takes a `pid()` per its spec but the value
   returned by `request/5` in async mode is documented as
   `reference()`.** It's actually `self()` of the connection
   gen_statem (see `../barrel_inference/_build/default/lib/hackney/src/hackney_conn.erl:2173`),
   so a pid. The dialyzer suppression list at the top of
   `barrel_inference_fetch_worker.erl` deals with the spec mismatch.
3. **Redirects are not followed in async mode.** Even with
   `{follow_redirect, true}`, a 301/302/307/308 response sends a
   `{hackney_response, Pid, {redirect, Loc, _}}` message. The
   worker explicitly re-issues the request to the new URL with a
   bounded retry counter (`stream_with_redirects/7`). Ollama blob
   URLs redirect to Cloudflare R2; this is hit on every Ollama
   fetch.
4. **`with_body` is deprecated and ignored.** The body is always
   returned inline by sync `request/5`. Async mode delivers chunks
   as `{hackney_response, Pid, Bin}` messages.

## Architecture to port

The shape is:

```
barrel_inference_server_sup
└── barrel_inference_fetch_subtree
    ├── barrel_inference_fetch_sup        % simple_one_for_one workers
    └── barrel_inference_fetch_srv        % gen_server: dedupe + lifecycle
```

The srv state:

```erlang
-record(state, {
    jobs = #{} :: #{binary() => #job{}},
    done = #{} :: #{binary() => #done_entry{}}
}).

-record(job, {
    parsed, worker, monitor,
    subscribers = [],     %% blocking gen_server:from() callers
    progress_pids = [],   %% receive {barrel_inference_fetch_progress, Hash, Bytes, Total}
    done_pids = [],       %% receive {barrel_inference_fetch_done, Hash, Result}
    progress = #progress{phase = starting, bytes = 0, total = undefined}
}).
```

Phases reported on the wire: `starting → resolving → streaming →
done`. `resolving` covers the HF siblings GET (auto-pick) and the
Ollama manifest GET; `streaming` starts the moment the body GET's
headers arrive.

Async lifecycle from `download_async/2`:

1. Caller is auto-subscribed via `done_pids`.
2. Worker is spawned under `barrel_inference_fetch_sup`.
3. Worker resolves (HF/Ollama metadata) and casts `{phase, _, _}`.
4. Worker streams the body, casts `{progress, _, B, T}` ~10/s.
5. On completion the srv:
   - replies to `subscribers` (sync `download/2` and `await/2`),
   - sends `{barrel_inference_fetch_done, Hash, Result}` to `done_pids`,
   - moves the entry to `done` with a 5-min TTL timer.

## Cache layout (keep it identical)

```
<root>/
  blobs/sha256-<hex>.gguf       % content-addressed
  refs/<spec_hash>.ref          % one-line text file with the absolute path
  tmp/<spec_hash>.part          % in-progress download
```

`<root>` resolution order (in `barrel_inference_fetch:cache_root/0`):

1. `application:get_env(barrel_inference, model_cache_dir)` (rename to
   `barrel_inference_server` when you port).
2. `XDG_CACHE_HOME/barrel_inference/models` (rename the suffix).
3. `filename:basedir(user_cache, "barrel_inference")/models` (ditto).

## Renames during the port

- App env key `barrel_inference.model_cache_dir` → `barrel_inference_server.model_cache_dir`.
- Application list in `.app.src`: add `hackney`, `ssl`, `inets`.
- Module names: keep `barrel_inference_fetch_*` and `barrel_inference_search_*` if you
  prefer (they don't claim the `barrel_inference_server_` namespace), or
  rename to `barrel_inference_server_fetch_*` for consistency with the rest
  of this app. Personal preference; the moduledocs will need light
  edits either way.
- The public façade: re-export `fetch/1,2`, `fetch_async/1,2`,
  `fetch_status/1`, `fetch_await/1,2`, `fetch_subscribe/2`, and
  `search/1,2` from `barrel_inference_server` (or expose a thin `barrel_inference_server_fetch`
  module — the existing `barrel_inference_server` module is the OTP `application`
  callback so don't bloat it).

## Integration with existing Barrel Inference Server processes

Once the port lands, the natural next step is to wire fetching into
the loader path so that `barrel_inference_server` can resolve a model id
that is not yet on disk:

- `../barrel_inference_server/src/barrel_inference_server_loader.erl` currently calls
  `barrel_inference:load_model(ModelId, default_opts(ModelId))` directly. Add
  a pre-step: if `default_opts(ModelId).model_path` is missing or
  the file does not exist, call `barrel_inference_server:fetch(ModelId)`
  first and feed the resulting path through.

That's a follow-up after this port — note it but don't implement here.

## Verification after porting

```bash
cd ../barrel_inference_server
rebar3 fmt --check
rebar3 compile         # adds hackney + transitive deps
rebar3 eunit           # ported tests stay green
rebar3 dialyzer
rebar3 lint
rebar3 xref
rebar3 ct
```

Live smoke test:

```erlang
1> {ok, _} = application:ensure_all_started(barrel_inference_server).
2> {ok, R} = barrel_inference_server:fetch_async(<<"hf://lmstudio-community/Qwen2.5-7B-Instruct-GGUF">>).
3> barrel_inference_server:fetch_status(R).
%% expect {pending, #{phase => streaming, ...}} after a second or two
4> receive {barrel_inference_fetch_done, R, X} -> X end.
{ok, "/Users/me/Library/Caches/barrel_inference_server/models/blobs/sha256-...gguf"}
```

## Cleanup follow-up (separate task, after this one)

Once `barrel_inference_server` is the source of truth for fetch + search:

1. Remove the modules listed at the top of this doc from `../barrel_inference/src/`.
2. Drop `fetch_*` / `search` exports from `../barrel_inference/src/barrel_inference.erl`.
3. Drop hackney from `../barrel_inference/rebar.config` and `applications`
   list in `../barrel_inference/src/barrel_inference.app.src`.
4. Remove the test files.
5. Move `../barrel_inference/guides/fetching.md` to `../barrel_inference_server/guides/`.
6. Update `../barrel_inference/README.md` and `CHANGELOG.md` to point at
   `barrel_inference_server` for the fetch + search story.
