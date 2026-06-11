---
name: operating-barrel
description: Use when running inference on, loading, tuning, or diagnosing a local Barrel Inference server. Triggers on barrel, barrel_infer, weight_residency, num_ctx, num_seq_max, KV cache reuse, resident_bytes, "model not loaded", "context limit", or "why is generation slow". Pairs with the barrel-inference MCP tools.
---

# Operating Barrel Inference

The `barrel-inference` MCP tools let you run and operate a local barrel engine.
This skill is the judgment for using them well. The tools talk to the barrel
daemon (default `http://localhost:8080`).

## Standard workflow

`barrel_list_models` (what is loaded) → `barrel_show_model` (current params) →
`barrel_edit_model` (only if a param is wrong) → run `barrel_infer`. For any
large prompt, call `barrel_count_tokens` first and compare against the model's
`num_ctx` from `barrel_show_model`.

Loading is implicit: the first `barrel_infer` on a cold model takes a few extra
seconds while weights load. That is not a hang.

## Weight residency

`barrel_edit_model weight_residency` controls how model weights sit in memory:

- `eager` (default): kernel readahead of the whole file.
- `lazy`: pages fault in on first touch (`MADV_RANDOM`). Low startup, but every
  decode can stall on disk faults.
- `pinned`: `mlock` the entire model up front. Fast, high fixed memory.
- `lazy_then_pin_resident`: lazy load, then `mlock` the resident pages after the
  first request. Best balance for a frequently-used model.

Verify residency with `barrel_metrics`, not by guessing: compare a model's
`resident_bytes` against its on-disk size. If `resident_bytes` is well below the
model size and generation is slow, the weights are faulting from disk. Fix:
`barrel_edit_model weight_residency=lazy_then_pin_resident`, then warm the model
(one tiny `barrel_infer`) and re-check `resident_bytes`.

## Context limits

barrel returns HTTP 400 "Context limit reached" when a request exceeds the
model's `num_ctx`. It does not silently truncate. The tool surfaces this with a
hint. To raise the window: `barrel_edit_model num_ctx=<bigger>` (capped by the
daemon's `max_context_size`), then retry.

## Session reuse (KV cache)

Pass a stable `session_id` to `barrel_infer` across turns of the same
conversation. barrel pins the sequence and reuses the warm KV cells for the
shared prefix instead of re-prefilling, so multi-turn is much faster. Use a
fresh `session_id` for unrelated work.

Constraint: keep `num_seq_max` at least as large as the number of concurrent
sessions, or concurrent requests can deadlock waiting for a sequence slot. If
you raise `num_seq_max` with `barrel_edit_model`, the change applies on the next
load of the model.

## Diagnosing slow generation

Call `barrel_metrics` and read the per-model fields in this order:

1. `queue_depth` > 0 or `pool_exhausted_total` rising → requests are queuing or
   being rejected (429). Raise `num_seq_max`, or reduce concurrency.
2. `tokens_per_second_avg` low for the model size → check `resident_bytes` next.
3. `resident_bytes` well below model size → weights faulting from disk; switch to
   `lazy_then_pin_resident` (see Weight residency).
4. `cache` mostly `cold` across turns that should share a prefix → you are not
   passing a stable `session_id` to `barrel_infer`.

## Editing models is confirm-first

`barrel_edit_model` changes runtime behavior. Confirm with the user before
applying, and report what you changed. Only `num_ctx`, `num_batch`,
`num_seq_max`, `weight_residency`, and `n_gpu_layers` are editable through the
tool; registry edits (delete, copy, create) are intentionally not exposed.
