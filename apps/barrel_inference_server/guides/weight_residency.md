# Weight residency

Barrel inference loads a model by mmapping its GGUF, so weights live in
the kernel's page cache rather than the BEAM heap. The `weight_residency`
knob controls *which* of those pages the kernel pulls in eagerly,
whether they get pinned, and what your process actually accounts for in
RSS. Four modes ship; one is the default; the rest exist for specific
operational shapes.

The right mode rarely affects tokens-per-second on a given box — pages
that are resident cost the same to read regardless of which knob put
them there. The point is *which* pages are resident *when*.

## The four modes

| mode | use_mmap | use_mlock | madvise | meant for |
|---|---|---|---|---|
| `eager` (default) | true | false | `WILLNEED` | warm boxes, single-tenant, plenty of RAM |
| `lazy` | true | false | `RANDOM` | sparse-prompt agent workloads, multi-tenant boxes that share one model |
| `pinned` | true | true | `WILLNEED` | latency-sensitive fleet nodes that cannot tolerate paging jitter |
| `lazy_then_pin_resident` | true | false then true on first request done | `RANDOM` then `WILLNEED` | "discover the working set, then pin it"; closest to the per-prompt expert routing pattern from Apple's AFM3 / instruction-following pruning research |

### When each makes sense

- **`eager`**: the right default. The kernel reads weights ahead at load
  time so the first prefill does not stall waiting on the disk. If you
  have enough RAM and one model per box, leave this on.
- **`lazy`**: skip the read-ahead. Weights page in only when a prompt
  touches them. Process RSS stays small (on macOS the shared file-backed
  pages are not billed against the BEAM until they are mlocked). The
  first prefill takes a hair longer; steady-state tok/s is identical.
- **`pinned`**: `mlock` the entire model. Pages cannot be evicted under
  memory pressure. Predictable latency, biggest RSS bill. Use when a
  jitter SLO matters and the host has spare RAM.
- **`lazy_then_pin_resident`**: load lazy, then after the first request
  completes the scheduler calls `mincore(2)` to find which pages got
  faulted in and `mlock(2)`s just that set. New regions touched on
  later prompts still page in lazily but are not pinned. One-shot per
  model load; failures (e.g. `RLIMIT_MEMLOCK` exhausted) are logged and
  the model continues unpinned.

### Setting the mode

Three places, in precedence order (top wins):

1. **Modelfile parameter** (override per running model)
   ```
   FROM hf.co/some/model:Q4_K_M
   PARAMETER weight_residency lazy
   ```

2. **Manifest** (set at pull time or via `/api/edit`)
   ```json
   {
     "loader": {
       "n_ctx": 8192,
       "weight_residency": "lazy_then_pin_resident"
     }
   }
   ```

3. **App env default** (fleet-wide)
   ```erlang
   {barrel_inference_server, [
     {weight_residency_default, lazy}
   ]}
   ```

Unknown values fall back to the default with a `logger:warning/2`; they
do not refuse the load.

## Observability

The Prometheus gauge `barrel_inference_resident_bytes{model=...}` reports
the bytes of a loaded model's mmap regions currently faulted in. It's
sampled per `/metrics` scrape via `mincore(2)` and reports the same
quantity as the runtime API `barrel_inference:resident_bytes/1`. Note
that `mincore` counts pages in the page cache regardless of which
process triggered them, so once a host has loaded any copy of the
model, the gauge will saturate at that model's effective working-set
size.

For one-shot diagnostic checks, call from a remote shell:

```erlang
1> barrel_inference:resident_bytes(<<"my-model">>).
13352206336
```

Pair with process RSS (`ps -o rss= -p <pid>`) to see the lazy / pinned
distinction: on macOS shared file-backed pages do not count against the
BEAM's RSS unless they are mlocked, so a `lazy` model with 13 GB
resident may show only a few hundred MB of process RSS.

## Bench numbers

See [Weight residency bench](../../barrel_inference/internals/weight-residency-bench.md)
for measured values across the four modes on Devstral 24B Q4 on an
Apple M4 Pro. Headline:

| mode | RSS @ idle | mincore-resident | tok/s |
|---|---:|---:|---:|
| `eager` | 8.5 GB | 13.3 GB | 7.8 |
| `lazy` | 0.7 GB | 13.3 GB | 7.8 |
| `pinned` | 14.0 GB | 13.3 GB | 7.7 |
| `lazy_then_pin_resident` | 14.0 GB (post-first-request) | 13.3 GB | 7.7 |

## Platform caveats

- **macOS**: `mlock` needs `RLIMIT_MEMLOCK` raised. The hard limit on a
  default workstation is enough for a 24 GB model; for larger models or
  multi-model boxes raise it via `launchctl limit memlock`.
- **Linux**: `mlock` needs `CAP_IPC_LOCK` or a raised `memlock` limit
  (`security.conf`). Containerised deployments typically pass
  `--cap-add IPC_LOCK` or set `memlock: -1` in the compose file.
- All `mlock` failures (`EAGAIN`, `EPERM`, `ENOMEM`) degrade to a logger
  warning, not a crash. The model keeps serving; the gauge will show the
  actual resident set so you can confirm the pin did not happen.

## How it maps to llama.cpp

Internally the mode resolves to a triple on `llama_model_params`:

| mode | `use_mmap` | `use_mlock` | `prefetch` |
|---|---|---|---|
| `eager` | true | false | true |
| `lazy` | true | false | false |
| `pinned` | true | true | true |
| `lazy_then_pin_resident` | true | false | false |

The `prefetch` field is a barrel-local addition to the vendored
llama.cpp tree (it threads through `llama_model_loader::init_mappings`
to flip `posix_madvise` between `WILLNEED` and `RANDOM`). The
post-load `mlock` for `lazy_then_pin_resident` uses two more local
accessors (`llama_model_n_mappings`, `llama_model_get_mapping`) so the
NIF can call `mincore`/`mlock` against the model's mmap regions without
breaking llama.cpp's pimpl encapsulation.
