# MCP plugin (Claude Code)

Barrel ships an [MCP](https://modelcontextprotocol.io) server that exposes the
running daemon to MCP clients (Claude Code, Claude Desktop, or any MCP host).
It turns the engine into callable tools: run inference, list and tune models,
and read cache/residency metrics, without leaving the chat.

The repo doubles as a Claude Code **plugin marketplace**, so installation is two
slash commands. The plugin bundles the MCP server plus an operating skill that
teaches Claude how to use the tools well.

## What it exposes

The server is a thin client of the barrel HTTP daemon (it does not embed the
runtime). Each tool wraps one daemon endpoint:

| Tool | Wraps | Purpose |
|------|-------|---------|
| `barrel_infer` | `POST /v1/chat/completions` | One non-streaming completion. A stable `session_id` reuses the KV-cache prefix across turns. |
| `barrel_count_tokens` | `POST /v1/messages/count_tokens` | Token pre-flight against `num_ctx`. |
| `barrel_list_models` | `GET /v1/models` + `GET /api/ps` | Registered models merged with resident ones (`expires_at`, `size_vram`). |
| `barrel_show_model` | `POST /api/show` | Manifest with the resolved parameters block. |
| `barrel_edit_model` | `POST /api/edit` | Tune `num_ctx`, `num_batch`, `num_seq_max`, `weight_residency`, `n_gpu_layers` (whitelisted). |
| `barrel_metrics` | `GET /metrics` | Structured digest of the barrel Prometheus series. |
| `barrel_health` | `GET /health/ready` | Readiness and loaded models. |

Streaming and the redundant `/api/generate`, `/api/chat`, `/v1/completions`,
`/v1/responses` dialects are intentionally not exposed; registry edits
(`create`/`copy`/`delete`) stay human-driven.

## Build

The server is the `barrel_inference_mcp` umbrella app. Compile the umbrella so
the launcher can find the beams:

```sh
rebar3 compile
```

That is the only prerequisite. The plugin launcher
(`plugin/barrel-inference/bin/barrel-inference-mcp`) boots an Erlang node
against `_build/default/lib`, runs the MCP stdio loop, and routes all Erlang
logging to stderr so stdout stays a clean JSON-RPC channel.

## Install in Claude Code

```text
/plugin marketplace add https://github.com/barrel-platform/barrel_inference.git
/plugin install barrel-inference@barrel-inference
```

Claude Code starts the MCP server from `plugin/barrel-inference/.mcp.json` and
loads the `operating-barrel` skill. Point the server at a non-default daemon by
setting `BARREL_URL` in that `.mcp.json` `env` block (default
`http://localhost:8080`).

The barrel daemon must be running (see the [Quickstart](quickstart.md)); the
MCP server connects to it over HTTP.

## Use it

Type plain English. Claude maps intent to the tools:

```text
> what models do I have loaded in barrel?
> run llama3:8b on "explain the CAP theorem in one paragraph" and tell me how slow it is
> why is generation slow?
```

For the last one the `operating-barrel` skill drives the diagnosis: read
`barrel_metrics` in order (queue depth, then tokens/sec, then `resident_bytes`),
and if weights are faulting from disk, propose
`barrel_edit_model weight_residency=lazy_then_pin_resident`. `barrel_edit_model`
is confirm-first: Claude asks before changing runtime parameters.

## Use the server directly

Without the plugin, run either transport from an Erlang shell:

```erlang
%% stdio (point any MCP client at this process)
barrel_inference_mcp:run_stdio().

%% Streamable HTTP for remote clients
barrel_inference_mcp:start_http(#{port => 9090}).
```

## Other MCP clients

Any MCP host can use the stdio launcher. Example client config:

```json
{
  "mcpServers": {
    "barrel-inference": {
      "command": "/path/to/barrel_inference/plugin/barrel-inference/bin/barrel-inference-mcp",
      "env": { "BARREL_URL": "http://localhost:8080" }
    }
  }
}
```

## Notes

- A stable `session_id` on `barrel_infer` is what makes multi-turn fast; without
  it every call is a cold prefill. Keep `num_seq_max` at least as large as the
  number of concurrent sessions.
- The tools degrade cleanly when the daemon is down: calls return an MCP tool
  error with the HTTP status, not a crash.
