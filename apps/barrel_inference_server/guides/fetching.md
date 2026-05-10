# Fetching models

`erllama_server_fetch:fetch/1,2` pulls a GGUF from a remote source
onto the local disk and returns the path you can then pass to
`erllama:load_model/1`. Supports HuggingFace, the Ollama registry,
plain HTTPS URLs, and local paths (passthrough). Resumable, sha256-
verified, with progress events.

```erlang
1> {ok, _} = application:ensure_all_started(erllama_server).
2> {ok, Path} = erllama_server_fetch:fetch(<<"hf://TheBloke/TinyLlama-1.1B-Chat-GGUF/tinyllama-1.1b-chat.Q4_K_M.gguf">>).
{ok, "/Users/me/Library/Caches/erllama_server/models/blobs/sha256-cf46c7....gguf"}
3> {ok, M} = erllama:load_model(#{model_path => Path, ...}).
```

## Spec syntax

| Scheme | Form | Example |
|---|---|---|
| HuggingFace | `hf://<org>/<repo>/<path>[@<revision>]` | `hf://TheBloke/TinyLlama-1.1B-Chat-GGUF/tinyllama-1.1b-chat.Q4_K_M.gguf` |
| Ollama | `ollama://<library>/<name>[:<tag>]` | `ollama://library/llama3:8b` |
| HTTPS | `https://...` (and `http://`) | `https://cdn.example.com/m.gguf` |
| Passthrough | `file:///abs/path` or `/abs/path` | `/srv/models/m.gguf` |

The HuggingFace revision defaults to `main`. The Ollama tag defaults
to `latest`. Passthrough specs do not copy the file; they are
returned verbatim if they exist.

## Async fetch

Multi-GB downloads can run for minutes. To avoid blocking the caller,
use the async API: kick off the fetch, get a `JobRef` back, then
either subscribe to the completion message or poll status:

```erlang
1> {ok, Ref} = erllama_server_fetch:fetch_async(<<"hf://lmstudio-community/Qwen2.5-7B-Instruct-GGUF">>).
{ok,<<"a3f1...">>}

2> erllama_server_fetch:fetch_status(Ref).
{pending, #{bytes => 1048576, total => 4368450208}}

3> receive
       {erllama_fetch_done, Ref, {ok, Path}} -> Path;
       {erllama_fetch_done, Ref, {error, Reason}} -> {error, Reason}
   end.
"/Users/me/Library/Caches/erllama_server/models/blobs/sha256-cf46c7....gguf"
```

The caller of `fetch_async/1,2` is auto-subscribed: the message
`{erllama_fetch_done, JobRef, Result}` is delivered exactly once
when the fetch completes. To subscribe an additional pid (a UI
process, a status page, etc.) use `fetch_subscribe/2`.

To block synchronously on a previously-started job (with an optional
timeout), use `fetch_await/1,2`:

```erlang
{ok, Ref}  = erllama_server_fetch:fetch_async(Spec).
{ok, Path} = erllama_server_fetch:fetch_await(Ref).            % infinity
{ok, Path} = erllama_server_fetch:fetch_await(Ref, 60_000).    % 60 s, returns `timeout` past that
```

The `done` map keeps each completed job around for 5 minutes so
late `fetch_status/1`/`fetch_await/2` queries succeed. After that
window the job is reaped; `fetch_status/1` returns `not_found`.

## Auto-picking a GGUF inside a repo

If the HF spec omits the file path, the worker calls
`https://huggingface.co/api/models/<org>/<repo>` to list the repo's
files and picks a GGUF for you. The preference order is `Q4_K_M >
Q5_K_M > Q4_0 > Q8_0`, falling back to the first `.gguf` alphabetically:

```erlang
{ok, Path} = erllama_server_fetch:fetch(<<"hf://lmstudio-community/Qwen2.5-7B-Instruct-GGUF">>).
%% picks Qwen2.5-7B-Instruct-Q4_K_M.gguf
```

Pass an explicit file path to override the pick:

```erlang
{ok, Path} = erllama_server_fetch:fetch(<<"hf://lmstudio-community/Qwen2.5-7B-Instruct-GGUF/Qwen2.5-7B-Instruct-Q8_0.gguf">>).
```

## Searching

`erllama_server_search:search/1,2` queries HuggingFace and the
Ollama registry and returns a unified hit list. Each hit's `id` is
a fetch spec you can hand straight to
`erllama_server_fetch:fetch/1`.

```erlang
1> {ok, Hits} = erllama_server_search:search(<<"qwen">>, #{limit => 5, sources => [hf]}).
2> [maps:get(id, H) || H <- Hits].
[<<"hf://lmstudio-community/Qwen2.5-7B-Instruct-GGUF">>,
 <<"hf://Qwen/Qwen2.5-Coder-7B-Instruct-GGUF">>,
 ...]
```

Hit shape:

```erlang
#{
    source        => hf | ollama,
    id            => <<"hf://org/repo">> | <<"ollama://library/name">>,
    name          => <<"Org/Repo">>,
    description   => <<>>,
    downloads     => 12345,
    last_modified => <<"2025-...">>,
    tags          => [<<"text-generation">>, <<"gguf">>],
    files         => [#{id := <<"hf://...">>, path := <<"...">>}]
}
```

Options:

- `limit` (default 20) cap per source.
- `sources` (default `[hf, ollama]`) restrict registries.
- `hf_filter` (default `gguf`) `gguf | safetensors | any`.
- `timeout_ms` (default 10 000) per-registry HTTP timeout.

Notes:

- Ollama metadata is sparse: the registry catalog API returns
  repository names only. `description`, `downloads`, and
  `last_modified` are empty strings/zero for Ollama hits.
- HF results sort by download count (descending). Apply your own
  ordering on the merged list if you want a different ranking.

## Authentication

`HF_TOKEN` is honoured for HuggingFace. Set it before booting the
node and gated repos work transparently:

```bash
export HF_TOKEN=hf_xxx
rebar3 shell
```

```erlang
1> erllama_server_fetch:fetch(<<"hf://meta-llama/Llama-3.1-8B-Instruct-GGUF/llama-3.1-8b-instruct.Q4_K_M.gguf">>).
```

Plain HTTPS sources currently do not support per-call basic auth or
custom headers; if you need those, fetch the file with `curl` once
and pass the resulting path through `file://`.

## Options

```erlang
erllama_server_fetch:fetch(Spec, #{
    sha256   => <<"cf46c7128b...">>,    % verify against this digest
    progress => self(),                  % receive progress messages
    timeout  => 60_000,                  % per-request, default 30 s
    force    => true                     % bypass the cache, redownload
}).
```

- `sha256` 64-byte hex (or 32-byte raw) digest. The streamed bytes
  are folded into a sha256 context; on completion the result is
  compared against this value. A mismatch deletes the partial file
  and returns `{error, {sha256_mismatch, Got, Want}}`.
- `progress` a pid that receives
  `{erllama_fetch_progress, Ref, BytesDone, Total :: integer() | undefined}`
  every ~100 ms during the stream. `Total` is `undefined` if the
  server omitted `Content-Length`.
- `timeout` per-request HTTP timeout. The whole fetch can take much
  longer; this caps individual `recv_timeout`/`connect_timeout` in
  hackney.
- `force` skip the cache lookup and refetch.

## Cache layout

Cache root resolution, in order:

1. `application:get_env(erllama_server, model_cache_dir)`.
2. `$XDG_CACHE_HOME/erllama_server/models` (Linux/BSD when set).
3. `filename:basedir(user_cache, "erllama_server")/models` the
   OTP-native per-platform location
   (`~/Library/Caches/erllama_server/models` on macOS,
   `~/.cache/erllama_server/models` on Linux,
   `%LOCALAPPDATA%\erllama_server\models` on Windows).

Override per-deployment in `sys.config`:

```erlang
{erllama_server, [
    {model_cache_dir, "/srv/erllama/cache"}
]}.
```

Layout under the root:

```
<root>/
  blobs/sha256-<hex>.gguf       % the data, named by digest
  refs/<spec_hash>.ref          % UTF-8 file: absolute path to the blob
  tmp/<spec_hash>.part          % in-progress download (auto-resumed)
```

Two specs that resolve to the same content (for example, the same HF
file referenced by two URLs) share one blob via two refs. The cache
is content-addressed so a stale ref always points at a byte-identical
file.

## Resume semantics

If the streaming fetch dies (network drop, OS reboot, Ctrl-C), the
`.part` file stays on disk. The next call sends a `Range:
bytes=<offset>-` request and continues where the previous one left
off. The server choosing to ignore the `Range` (returning `200 OK`)
restarts cleanly from offset 0; correctness is preserved because the
running sha256 is reset whenever the server doesn't honour the
range.

Resume re-reads the existing `.part` once to seed the sha256 context.
That's an O(N) disk read on every resumed call, but always cheaper
than re-downloading.

## Concurrent-fetch dedupe

`erllama_server_fetch_srv` keys in-flight jobs by spec hash. If two
callers ask for the same spec while a worker is running, the second
caller attaches to the existing subscriber list instead of spawning
a second worker. Both receive the same final reply (and progress
events, if requested).

This means a multi-process server can call
`erllama_server_fetch:fetch/1` from every request handler without
coordinating; the first one to ask triggers the download, every
other concurrent request blocks on the shared worker.

## Verification

| Source | Expected digest | Verified? |
|---|---|---|
| `hf://...` | LFS `X-Linked-ETag` from a HEAD probe | yes, when present |
| `ollama://...` | `sha256:` from the manifest's model layer | yes, always |
| `https://...` | from caller's `opts.sha256` | only if you supply one |
| `file://...` | n/a (existence check only) | n/a |

When no digest is available, the file is still streamed under a
sha256 context; its digest is recorded in the blob filename so
future calls with the same caller-supplied `opts.sha256` will hit
the cache without redownloading.

## Errors

| Return | Meaning |
|---|---|
| `{error, {unsupported_spec, _}}` | bad URL syntax |
| `{error, {bad_hf_spec, _}}` | hf:// URL missing org/repo/path |
| `{error, {bad_ollama_spec, _}}` | ollama:// URL missing library/name |
| `{error, {http_status, N}}` | upstream returned non-2xx |
| `{error, {sha256_mismatch, Got, Want}}` | digest verification failed |
| `{error, {ollama_manifest_status, N}}` | Ollama registry returned non-200 for the manifest |
| `{error, ollama_no_model_layer}` | manifest had no `application/vnd.ollama.image.model` layer |
| `{error, {worker_crashed, Reason}}` | the streaming process died unexpectedly |
| `{error, {enoent, Path}}` | passthrough target does not exist |

## Limitations

- No per-call basic auth or custom headers for HTTPS specs (use
  `file://` after `curl` for now).
- No proxy configuration knob; hackney honours `HTTP_PROXY` /
  `HTTPS_PROXY` env vars by default.
- HuggingFace API tokens, when present, are sent on cross-host
  redirects only if hackney's `location_trusted` is set; currently
  the default (off). Gated-repo redirects to `cdn-lfs.huggingface.co`
  do not need the token.
