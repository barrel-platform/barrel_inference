# barrel_inference_mcp

MCP server that exposes the local Barrel Inference runtime to MCP clients
(Claude Code, Claude Desktop, or any MCP host).

It is a thin client of the barrel HTTP daemon. Point it at the daemon with
`BARREL_URL` (default `http://localhost:8080`); it works whether co-located
with the daemon or remote.

## Tools

| Tool | Wraps | Purpose |
|------|-------|---------|
| `barrel_infer` | `POST /v1/chat/completions` | One non-streaming completion; `session_id` reuses the KV-cache prefix |
| `barrel_count_tokens` | `POST /v1/messages/count_tokens` | Token pre-flight against `num_ctx` |
| `barrel_list_models` | `GET /v1/models` + `GET /api/ps` | Registered + resident models |
| `barrel_show_model` | `POST /api/show` | Manifest + resolved parameters |
| `barrel_edit_model` | `POST /api/edit` | Tune `num_ctx`/`num_batch`/`num_seq_max`/`weight_residency`/`n_gpu_layers` |
| `barrel_metrics` | `GET /metrics` | Structured digest of the barrel Prometheus series |
| `barrel_health` | `GET /health/ready` | Readiness + loaded models |

## Running

The server needs the umbrella compiled (`rebar3 compile`). Two transports:

```erlang
%% stdio (Claude Code / Desktop) — blocking
barrel_inference_mcp:run_stdio().

%% Streamable HTTP (remote clients)
barrel_inference_mcp:start_http(#{port => 9090}).
```

The Claude Code plugin under `plugin/barrel-inference/` launches the stdio
transport via `bin/barrel-inference-mcp`.
