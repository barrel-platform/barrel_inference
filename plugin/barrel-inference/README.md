# barrel-inference plugin (Claude Code, Codex, Gemini)

Operate the local [Barrel Inference](https://github.com/barrel-platform/barrel_inference)
engine from an MCP host. Bundles one MCP server (the engine as callable tools)
plus the operating guidance, wired for three hosts off the same stdio launcher.

## Install

**Claude Code**

```text
/plugin marketplace add https://github.com/barrel-platform/barrel_inference.git
/plugin install barrel-inference@barrel-inference
```

**OpenAI Codex** — add the server to `~/.codex/config.toml`:

```sh
codex mcp add barrel_inference --env BARREL_URL=http://localhost:8080 \
  -- /ABS/PATH/barrel_inference/plugin/barrel-inference/bin/barrel-inference-mcp
```

(see [`codex-config.toml`](codex-config.toml) for the full block).

**Gemini CLI** — install the extension:

```sh
gemini extensions install https://github.com/barrel-platform/barrel_inference.git
```

Prerequisites (all hosts): the umbrella compiled (`rebar3 compile`) and the
barrel daemon running (default `http://localhost:8080`; override with
`BARREL_URL`). If a host runs from a different location than your compiled
checkout, set `BARREL_BUILD` to its `_build/default/lib`.

## Contents

- `.mcp.json` — Claude Code MCP wiring (stdio via `bin/barrel-inference-mcp`).
- `codex-config.toml` — Codex `~/.codex/config.toml` snippet.
- `bin/barrel-inference-mcp` — launcher shared by all hosts; boots the
  `barrel_inference_mcp` app against the build and runs the stdio loop.
- `skills/operating-barrel/SKILL.md` — operating guidance (Claude skill).

Host manifests at the repo root: `.claude-plugin/marketplace.json`,
`.codex-plugin/plugin.json`, `gemini-extension.json` + `GEMINI.md`.

## Tools

`barrel_infer`, `barrel_count_tokens`, `barrel_list_models`, `barrel_show_model`,
`barrel_edit_model`, `barrel_metrics`, `barrel_health`.

Full reference: [MCP plugin guide](../../docs/server/guides/mcp-plugin.md).
The server implementation lives in
[`apps/barrel_inference_mcp`](../../apps/barrel_inference_mcp).
