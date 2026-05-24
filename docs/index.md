# Barrel Inference

OTP-native LLM inference for the BEAM: dirty NIFs over `llama.cpp`, supervised
per-model processes, and a token-exact tiered KV cache, with an
OpenAI/Anthropic/Ollama-compatible HTTP daemon on top.

Inference as a first-class OTP citizen, not a Python sidecar. The wedge is
supervision, per-model queues, and cancel-on-disconnect, with the cache more
warm state than fits in RAM.

## The pieces

A rebar3 umbrella. Each app is a separately publishable Hex package; the repo
is versioned as a whole.

```
            barrel-inference  (CLI: serve / pull / run / ps)
                    │ HTTP
                    ▼
   ┌──────── barrel_inference_server (Erlang/OTP) ────────┐
   │  OpenAI · Anthropic · Ollama HTTP   ·   /metrics      │
   │  model registry · per-model queues · keep-alive       │
   └───────────────────────────┬───────────────────────────┘
                                ▼
              barrel_inference  (NIF over llama.cpp)
              supervised model processes · tiered KV cache
```

| App | What it is | Hex |
|-----|-----------|-----|
| [`barrel_inference`](runtime/guides/loading.md) | The runtime: dirty NIFs over llama.cpp, supervised model processes, token-exact tiered KV cache. | [hexdocs](https://hexdocs.pm/barrel_inference) |
| [`barrel_inference_server`](server/guides/quickstart.md) | The API daemon: OpenAI-, Anthropic-, and Ollama-compatible HTTP, registry, per-model queues, metrics. | [hexdocs](https://hexdocs.pm/barrel_inference_server) |
| [`barrel-inference`](cli.md) | The CLI: `serve` boots the daemon; `pull`/`run`/`ps`/`rm` drive a running one over HTTP. | — |

## Pick your path

**Running it (operators, app developers)**

- [Quickstart](server/guides/quickstart.md): boot the daemon and make a request.
- [CLI reference](cli.md): `serve`, `pull`, `run`, `ps`, and the rest.
- [HTTP API](server/guides/api.md): every endpoint as a curl one-liner, plus the [OpenAPI 3.1 spec](server/guides/openapi.md).
- [Clients](server/guides/clients.md): point the OpenAI / Anthropic / ollama SDKs at it.
- [Registry](server/guides/registry.md) and [Fetching](server/guides/fetching.md): pull and manage models.
- [Sizing](server/guides/sizing.md) and [Deployment](server/guides/deployment.md): pick a model that fits, then ship it.

**Embedding the runtime (Erlang/Elixir developers)**

- [Loading a model](runtime/guides/loading.md) and [Configuration](runtime/guides/configuration.md).
- [Caching](runtime/guides/caching.md): how the token-exact KV cache turns repeat prefill into a restore.
- [Tool calls](runtime/guides/tool-calls.md) and [Examples](runtime/guides/examples.md).
- [Building from source](runtime/guides/building.md): the vendored llama.cpp NIF and its backend toggles.

**Working on Barrel Inference (contributors)**

- [Cache design](runtime/internals/cache-design.md) and [Request lifecycle](runtime/internals/request-lifecycle.md).
- [Publish protocol](runtime/internals/publish-protocol.md): how cache rows are written and shared.
- [NIF safety](runtime/internals/nif-safety.md) and the [C safety audit](runtime/internals/c-safety-audit.md).
- [Updating llama.cpp](runtime/UPDATE_LLAMA.md).

## Install

```
barrel-inference serve                 # start the API server
barrel-inference pull <model>          # fetch a model
barrel-inference run <model> "hello"   # one-shot completion
```

Or with Docker: `docker compose up`. Build from source needs Erlang/OTP 28,
rebar3 3.25+, cmake, and a C/C++ toolchain for the NIF.

## Project links

- Source: <https://github.com/barrel-platform/barrel_inference>
- API reference: [barrel_inference](https://hexdocs.pm/barrel_inference) · [barrel_inference_server](https://hexdocs.pm/barrel_inference_server)
- Issues: <https://github.com/barrel-platform/barrel_inference/issues>
- Releases: <https://github.com/barrel-platform/barrel_inference/releases>

MIT licensed. Part of the [barrel-platform](https://github.com/barrel-platform) project.
