# Sizing: fitting a model on your machine

Practical guide to picking a model and tuning the loader for the
RAM you actually have. Most of the surprises here come from
**unified memory** on Apple Silicon (model weights, KV cache,
Metal compute buffers, and the page cache all share one pool) and
from **mmap behaviour** when a model is bigger than RAM.

## How the loader uses memory

When `barrel_inference_server` loads a GGUF, four things draw from the
unified memory pool:

| Allocation | Approximate size | Knob |
| --- | --- | --- |
| Model weights | quant size of the file (4 GB for a 7B Q4) | `loader.use_mmap` |
| KV cache | `n_ctx * n_kv_heads * head_dim * 2 (k+v) * dtype_bytes` per layer | `loader.context_opts.n_ctx`, `n_seq_max` |
| Metal compute buffers | hundreds of MB to single-digit GB depending on `n_batch` and model size | `loader.n_gpu_layers`, `loader.context_opts.n_batch` |
| OS page cache (mmap'd weights) | up to all remaining RAM | implicit |

The OS page cache is **where the weights actually live** when
`use_mmap = true` (the default). llama.cpp doesn't `read()` the
GGUF into a heap buffer; it `mmap()`s the file and lets macOS /
Linux page individual regions in on demand. The kernel uses
whatever RAM you have left over after the explicit allocations
above as a transparent disk cache for those pages.

This is good news for models bigger than RAM: the loader doesn't
OOM at load time. It just runs slow until the working set is
warm.

Picking *which* of those pages get pulled into RAM, and whether they
stay there, is the [Weight residency](weight_residency.md) knob. The
default (`eager`) reads weights ahead at load time; `lazy` defers them
to first touch; `pinned` mlocks the whole file; `lazy_then_pin_resident`
discovers the working set then pins just that. On a tight memory budget
this is the main thing to tune.

## Picking by model class

For a typical Apple Silicon laptop, here's the comfortable-vs-
painful boundary by total RAM.

### 16 GB (M1 / M2 / M3 / M4 base)

Comfortable:

| Model | Q4 GGUF | Comment |
| --- | --- | --- |
| Llama-3.2-3B-Instruct | ~2.0 GB | Tiny first-token latency |
| Qwen2.5-3B-Instruct | ~2.0 GB | Same shape |
| Qwen2.5-Coder-7B-Instruct (Q3_K_M) | ~3.6 GB | Light coder workloads |
| Mistral-7B-Instruct (Q4_K_M) | ~4.4 GB | General chat |

Painful: anything above ~7 B Q4. KV cache plus Metal buffers plus
the OS' other claims on RAM leave too little page cache.

### 32 GB (M3 Pro, M4 Pro base)

Comfortable:

| Model | Q4 GGUF | Comment |
| --- | --- | --- |
| Qwen2.5-Coder-14B-Instruct | ~9 GB | Strong coder, fits with room |
| DeepSeek-V2-Lite-Chat (MoE, 2.4B active) | ~10 GB | Very fast for size |
| Qwen2.5-14B-Instruct | ~9 GB | General chat |

Painful: 30 B+ dense models. Will run via mmap paging but tokens
per second drop noticeably.

### 48 GB (M4 Pro 48 GB, M2/M3 Max)

Comfortable:

| Model | Total / Active | Q4 GGUF | Comment |
| --- | --- | --- | --- |
| **Qwen3-30B-A3B-Instruct** (MoE) | 30 B / 3 B | ~18 GB | **Sweet spot for Claude Code workloads** |
| Qwen2.5-Coder-32B-Instruct (dense) | 32 B | ~19 GB | Strongest coder that fits |
| DeepSeek-V2-Lite-Chat (MoE) | 16 B / 2.4 B | ~10 GB | Fast, light |
| Qwen2.5-Coder-7B-Instruct (dense) | 7 B | ~4.5 GB | Tons of headroom, very fast first token |

Painful: DeepSeek-V4-Flash class (250 B+ total params). See the
"too big to fit" section below.

### 64 GB+ (M3/M4 Max 64+, M3 Ultra)

Most current open-weights models fit comfortably:
70 B Q4 (~40 GB), Qwen3-235B-A22B Q3 (~110 GB if dual-channel),
DeepSeek-V3-Lite class. Stop sweating sizing; tune for latency
instead.

## Running a model bigger than RAM

The hypothetical case the rest of this guide leans on: you want
DeepSeek-V4-Flash (or any model whose Q4 GGUF is 100 GB+) on a
48 GB host. You can run it — it will just be slow. Tuning that
trades latency for fit:

```json
{
  "name": "deepseek-v4-flash",
  "tag": "main",
  "loader": {
    "n_ctx": 8192,
    "n_batch": 256,
    "n_seq_max": 1,
    "use_mmap": true,
    "use_mlock": false,
    "n_gpu_layers": 0,
    "context_opts": { "n_ctx": 8192, "n_batch": 256, "n_seq_max": 1 }
  }
}
```

What each knob does for the too-big-to-fit case:

| Knob | Why this value |
| --- | --- |
| `use_mmap: true` | Required. Without it llama.cpp tries to `read()` the file into a heap buffer at load and OOMs immediately. |
| `use_mlock: false` | `mlock` pins pages so the kernel can't evict. Defeats the disk-as-overflow strategy. Leave off. |
| `n_gpu_layers: 0` | On a too-big-for-RAM model, Metal offload doesn't free memory — Metal allocates compute buffers in the same unified pool. CPU-only inference is slower per token but leaves more RAM for page cache, so end-to-end throughput is sometimes higher. Worth A/B-ing per model. |
| `n_ctx: 8192` (low) | KV cache scales with context size and is fully RAM-resident. Bigger context = less RAM for weight paging. Pick the smallest context your client actually uses. |
| `n_batch: 256` (low) | Smaller prefill batches mean smaller scratch buffers competing for RAM. Trades prefill throughput for paging headroom. |
| `n_seq_max: 1` | Multiple concurrent sequences each have a KV cache and their own expert-access pattern. Pin to 1 for big models on small RAM. |
| `decode_budget_ms` (engine) | Barrel Inference 0.8 aborts any decode step that exceeds this wall-clock budget and recovers the context in place instead of wedging. Default 30000 (30 s). A very large model on CPU can legitimately exceed 30 s on a heavy prefill step — raise it (or set `0` to disable) if you see spurious `decode_timeout`. Set globally via `decode_budget_ms` in `sys.config`, or per model via `loader.decode_budget_ms`. |

And in `sys.config`:

```erlang
{model_load_policy, on_demand},   %% loads on first request (default)
{per_model_pool_exhausted_policy, #{
  <<"deepseek-v4-flash:main">> => {queue, #{
    concurrency => 1,
    depth => 1,
    timeout_ms => 600000
  }}
}},
{keep_alive_default_ms, 60000}   %% 1 minute idle -> unload
```

Why each:

- **`on_demand`** so RAM isn't tied up by a model nobody's using.
- **`concurrency: 1`** because a second concurrent request would
  thrash the page cache between two different working sets of an
  already-too-big model.
- **`depth: 1, timeout_ms: 600000`** lets a polite waiter queue
  but rejects fast on overload. The 10-minute timeout matches
  the worst-case prefill on a cold cache.
- **`keep_alive_default_ms: 60000`** unloads after a minute of
  idle so the next model can have the RAM.

## What 48 GB still can't do, regardless of tuning

- **Concurrent multi-model inference**. With one 100+ GB model in
  flight, you have maybe 30 GB of effective page cache after BEAM,
  Metal, and the OS itself. A second model immediately evicts the
  first's working set; both are slow.
- **Large contexts on big models**. 32 K context on a 200 GB model
  burns 5–10 GB of RAM on KV alone, leaving very little for page
  cache. Each prefill ends up disk-bound.
- **Tool-heavy agent workloads at native speed**. Many short
  turns each pay the cold-cache penalty after eviction. With
  7 GB/s SSD reads you can refill the working set in seconds,
  but seconds × N turns adds up.

## Putting it together for a Claude Code workload on 48 GB

Recommended baseline:

1. **Pick the model**: Qwen3-30B-A3B-Instruct (`Qwen/Qwen3-30B-A3B-Instruct-GGUF`,
   Q4_K_M, ~18 GB). MoE for low active-param compute, 30 B total
   parameters for breadth, fits with room to spare.
2. **Pull and copy under an alias**:
   ```sh
   barrel-inference pull hf://Qwen/Qwen3-30B-A3B-Instruct-GGUF/qwen3-30b-a3b-instruct-q4_k_m.gguf
   barrel-inference copy "Qwen/Qwen3-30B-A3B-Instruct-GGUF:main" "local-coder:main"
   ```
3. **Edit the manifest** at
   `~/Library/Caches/barrel_inference_server/models/manifests/local-coder/main.json`
   to set `loader.context_opts.n_seq_max = 4` (required for
   sticky-seq + Claude Code; see
   [clients.md](clients.md#sticky-seq-kv-reuse-across-turns)).
4. **Alias for Claude Code** in `config/sys.config`:
   ```erlang
   {model_aliases, #{
     <<"claude-opus-4-7">>            => <<"local-coder:main">>,
     <<"claude-sonnet-4-5">>          => <<"local-coder:main">>,
     <<"claude-haiku-4-5">>           => <<"local-coder:main">>,
     <<"claude-3-5-sonnet-20241022">> => <<"local-coder:main">>,
     <<"claude-3-5-haiku-20241022">>  => <<"local-coder:main">>
   }},
   ```
5. **Boot the daemon** and point Claude Code at it — see
   [clients.md](clients.md#end-to-end-walkthrough) for the rest.

You'll get a Claude Code drop-in that fits comfortably in 48 GB
of unified memory, with KV reuse across turns and tool calling
on the v0.5 wire.

## Autoparser scheduler pressure

Every chat / messages request runs through llama.cpp's
`common_chat_*` autoparser, which lives on the BEAM's **dirty CPU
scheduler pool**. A request typically pays two trips into the NIF:

- A jinja render (cheap, ~ms for a 700-token prompt).
- A PEG parse over the buffered model response when generation
  finishes (can climb into tens of ms for multi-thousand-token
  outputs with rich tools).

Dirty schedulers exist exactly so these long C++ calls do not stall
the normal scheduler pool that runs HTTP handlers, gen_statems, and
SSE writes — but the dirty pool itself has a fixed thread count.
When all of them are busy, new dirty-NIF calls queue.

Two metrics to watch:

- `barrel_inference_dirty_cpu_scheduler_util{kind="dirty_cpu"}` —
  per-scheduler busy ratio (0..1), sampled per `/metrics` scrape.
  Sustained values above ~0.8 on every thread mean the pool is the
  bottleneck.
- `barrel_inference_chat_parse_duration_seconds` — histogram of
  parse wall-time. Pair with `barrel_inference_chat_apply_duration_seconds`
  (apply / render_only / make_params) to see whether pressure is
  parse-bound (typical) or apply-bound (rare after the PR #42 cache).

When the gauge stays saturated, raise the dirty CPU pool size in
`config/vm.args`:

```
+SDcpu 32
```

Default is the number of online schedulers (≈ CPU cores). Dirty
threads are cheap; pick a value that matches your expected
**concurrent autoparser request count**, not the core count.
Operators on 12-core boxes serving high-concurrency agent traffic
have used `+SDcpu 64` without problems.

The chat-templates params cache landed in PR #42 already cuts the
apply cost on repeat turns with the same tools schema (the common
agent-loop case), so steady-state pressure should be parse-bound
unless you see a high apply-duration p99.

## Reads to follow

- [`clients.md`](clients.md) — full Claude Code walkthrough,
  sticky-seq, `n_seq_max` gotcha.
- [`registry.md`](registry.md) — manifest layout, Modelfile
  overrides.
- [`fetching.md`](fetching.md) — pulling models from HF /
  Ollama / HTTPS / file://.
