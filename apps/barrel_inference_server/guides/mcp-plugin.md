# MCP plugin (Claude Code, Codex, Gemini)

Barrel ships an [MCP](https://modelcontextprotocol.io) server that exposes the
running daemon to MCP clients. It turns the engine into callable tools: run
inference, list and tune models, and read cache/residency metrics, without
leaving the chat.

One server, three hosts. MCP is the shared standard, so the same stdio launcher
(`plugin/barrel-inference/bin/barrel-inference-mcp`) plugs into **Claude Code**,
**OpenAI Codex**, and **Gemini CLI**; only the per-host config differs. Each host
also gets the same operating guidance (residency tuning, context limits, session
reuse, slow-generation diagnosis) as a skill or context file.

| Host | MCP wiring | Operating guidance |
|------|-----------|--------------------|
| Claude Code | `.claude-plugin/marketplace.json` + `plugin/barrel-inference/.mcp.json` | `skills/operating-barrel/SKILL.md` |
| OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.barrel_inference]`) | `.codex-plugin/plugin.json` -> skill |
| Gemini CLI | `gemini-extension.json` (`mcpServers`) | `GEMINI.md` context file |

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

## Install in Codex

Codex loads MCP servers from `~/.codex/config.toml`. Add the server (use an
absolute path to the launcher in your checkout):

```sh
codex mcp add barrel_inference \
  --env BARREL_URL=http://localhost:8080 \
  -- /ABS/PATH/barrel_inference/plugin/barrel-inference/bin/barrel-inference-mcp
```

or paste the equivalent block from
[`plugin/barrel-inference/codex-config.toml`](https://github.com/barrel-platform/barrel_inference/blob/main/plugin/barrel-inference/codex-config.toml)
into `~/.codex/config.toml`:

```toml
[mcp_servers.barrel_inference]
command = "/ABS/PATH/barrel_inference/plugin/barrel-inference/bin/barrel-inference-mcp"

[mcp_servers.barrel_inference.env]
BARREL_URL = "http://localhost:8080"
```

## Install in Gemini CLI

The repo is a Gemini CLI extension (`gemini-extension.json` at the root, with a
`GEMINI.md` context file). Install it from the repo or a local checkout:

```sh
gemini extensions install https://github.com/barrel-platform/barrel_inference.git
# or, from a local clone:
gemini extensions install /ABS/PATH/barrel_inference
```

Gemini starts the MCP server from `gemini-extension.json` (the launcher path is
resolved via `${extensionPath}`) and loads `GEMINI.md` as context. If the
extension is installed somewhere other than your compiled checkout, set
`BARREL_BUILD` to `<checkout>/_build/default/lib` in the extension's
`mcpServers.env` so the launcher finds the beams.

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
