# barrel-inference (Claude Code plugin)

Operate the local [Barrel Inference](https://github.com/barrel-platform/barrel_inference)
engine from Claude. Bundles an MCP server (the engine as callable tools) plus an
operating skill (how to use them).

## Install

```text
/plugin marketplace add https://github.com/barrel-platform/barrel_inference.git
/plugin install barrel-inference@barrel-inference
```

Prerequisites: the umbrella compiled (`rebar3 compile`) and the barrel daemon
running (default `http://localhost:8080`; override with `BARREL_URL` in
`.mcp.json`).

## Contents

- `.mcp.json` — starts the MCP server over stdio via `bin/barrel-inference-mcp`.
- `bin/barrel-inference-mcp` — launcher; boots the `barrel_inference_mcp` app
  against `_build/default/lib` and runs the stdio loop.
- `skills/operating-barrel/SKILL.md` — residency tuning, context limits, session
  reuse, and slow-generation diagnosis.

## Tools

`barrel_infer`, `barrel_count_tokens`, `barrel_list_models`, `barrel_show_model`,
`barrel_edit_model`, `barrel_metrics`, `barrel_health`.

Full reference: [MCP plugin guide](../../docs/server/guides/mcp-plugin.md).
The server implementation lives in
[`apps/barrel_inference_mcp`](../../apps/barrel_inference_mcp).
