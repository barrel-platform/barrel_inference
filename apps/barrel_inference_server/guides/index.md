# erllama_server

OpenAI-, Anthropic-, and Ollama-compatible HTTP server on top of
[erllama](https://github.com/erllama/erllama). One Erlang/OTP node;
real GGUF inference via llama.cpp under the hood. Drop-in for SDKs
that already speak any of those three APIs.

## Three API families, one process tree

```
┌───────────── erllama_server (Erlang/OTP) ─────────────┐
│                                                       │
│  OpenAI     /v1/chat/completions  /v1/completions     │
│             /v1/embeddings        /v1/models[/:id]    │
│                                                       │
│  Anthropic  /v1/messages                              │
│                                                       │
│  Ollama     /api/generate  /api/chat  /api/embed      │
│             /api/pull  /api/tags  /api/show  /api/copy │
│             /api/delete  /api/create  /api/ps         │
│             /api/version  /api/search                 │
│                                                       │
│  health     /health  /health/ready  /metrics          │
└───────────────────────────┬───────────────────────────┘
                            ▼
              erllama (NIF over llama.cpp)
```

## Pick your reading path

- New to it? Start with [Quickstart](quickstart.md).
- Want every endpoint as a curl one-liner? [HTTP API reference](api.md).
- Hooking up an SDK? [Client examples](clients.md) (Python OpenAI /
  Anthropic / ollama, JavaScript fetch, LangChain, LiteLLM, Claude Code).
- Pulling and managing models? [Registry guide](registry.md).
- Downloading internals? [Fetching guide](fetching.md).
- Machine-readable? [OpenAPI 3.1 spec](openapi.md).

## Highlights

- **Three API families** side by side with one supervised process tree.
- **Tool calling** via grammar-constrained sampling on the OpenAI
  and Anthropic paths.
- **Structured output** (`response_format` on OpenAI, `format` on
  Ollama). `"json"` and JSON Schema both compile to GBNF.
- **Model registry** with content-addressed blob cache. Pull from
  HuggingFace, Ollama, plain HTTPS, or `file://`. Resumable,
  sha256-verified.
- **Modelfile-compatible** `/api/create` with `FROM`, `PARAMETER`,
  `SYSTEM`, `TEMPLATE` directives.
- **Keep-alive eviction** counted by active requests so a long
  generation never trips the unload timer.
- **Cancel-on-disconnect** propagates back to llama.cpp.
- Prometheus `/metrics`, CORS preflight, `X-Request-ID` echo.
