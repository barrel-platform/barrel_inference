# erllama_server

[![Docs](https://img.shields.io/badge/docs-erllama.github.io%2Ferllama__server-blue)](https://erllama.github.io/erllama_server/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

OpenAI-, Anthropic-, and Ollama-compatible HTTP server on top of
[erllama](https://github.com/erllama/erllama). One Erlang/OTP node;
real GGUF inference via llama.cpp under the hood. Drop-in for SDKs
that already speak any of those three APIs, including the OpenAI
Python SDK, the Anthropic SDK, Claude Code as a local backend,
LangChain / LiteLLM connectors, and the `ollama` CLI shims.

**Documentation: <https://erllama.github.io/erllama_server/>**

```
┌───────────── erllama_server (Erlang/OTP, this repo) ─────────────┐
│                                                                  │
│  OpenAI       /v1/chat/completions  /v1/completions               │
│               /v1/embeddings        /v1/models[/:id]              │
│                                                                  │
│  Anthropic    /v1/messages                                        │
│                                                                  │
│  Ollama       /api/generate  /api/chat  /api/embed                │
│               /api/pull  /api/tags  /api/show  /api/copy          │
│               /api/delete  /api/create  /api/ps  /api/version     │
│               /api/search  /api/embeddings (legacy)               │
│                                                                  │
│  Observability  /health  /health/ready  /metrics (Prometheus)    │
└───────────────────────────────┬──────────────────────────────────┘
                                ▼
                  erllama (NIF over llama.cpp)
```

## Features

- **Three API families** side by side. OpenAI, Anthropic, and Ollama
  endpoints share one supervised process tree, one queue, one cache.
- **Tool / function calling** via grammar-constrained sampling on the
  OpenAI and Anthropic paths.
- **Structured output** (`response_format` on OpenAI, `format` on
  Ollama). `"json"` and JSON Schema both compile to GBNF.
- **Model registry** with content-addressed blob cache. Pull from
  HuggingFace, Ollama registry, plain HTTPS, or `file://`. Resumable,
  sha256-verified, with progress events.
- **GGUF metadata sniffing** at pull time (architecture, family,
  parameter size, quantisation, context length, chat template).
- **Keep-alive eviction**. Configurable per request (`keep_alive: 0`
  unloads immediately; `keep_alive: -1` keeps the model warm forever)
  with a server-wide default. Counted by active requests, so a long
  generation never trips the eviction timer.
- **Modelfile-compatible** `/api/create` with `FROM`, `PARAMETER`,
  `SYSTEM`, `TEMPLATE` directives.
- **Per-model FIFO queue** with `pool_exhausted` returning 429.
- **CORS preflight** + `X-Request-ID` echo.
- **Cancel-on-disconnect**: TCP close fires `erllama:cancel/1`, the
  queue slot is released, the inference stops.

## Quick start

```sh
# Build (one-off; pulls erllama + builds the native NIF)
rebar3 release

# Start the daemon (binds 0.0.0.0:8080 by default)
_build/default/rel/erllama_server/bin/erllama_server daemon

# Verify
curl http://127.0.0.1:8080/health
```

Then either point an SDK at `http://127.0.0.1:8080`, or use the
bundled CLI:

```sh
rebar3 escriptize                                     # builds _build/default/bin/erllama
export PATH=$PWD/_build/default/bin:$PATH

erllama pull hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf
erllama list
erllama run "Qwen/Qwen2.5-7B-Instruct-GGUF:main" "say hello"
erllama ps
erllama unload "Qwen/Qwen2.5-7B-Instruct-GGUF:main"
erllama version
```

Full guides under [`guides/`](guides/). Full OpenAPI 3.1 spec at
[`openapi.yaml`](openapi.yaml).

## Endpoint surface

| Family | Path | Method | Streaming |
|---|---|---|---|
| OpenAI | `/v1/chat/completions` | POST | SSE |
| OpenAI | `/v1/completions` | POST | SSE |
| OpenAI | `/v1/embeddings` | POST | no |
| OpenAI | `/v1/models[/:id]` | GET | no |
| Anthropic | `/v1/messages` | POST | SSE (named events) |
| Ollama | `/api/generate` | POST | NDJSON |
| Ollama | `/api/chat` | POST | NDJSON |
| Ollama | `/api/embed` | POST | no |
| Ollama | `/api/embeddings` (legacy) | POST | no |
| Ollama | `/api/pull` | POST | NDJSON |
| Ollama | `/api/tags` | GET | no |
| Ollama | `/api/show` | POST | no |
| Ollama | `/api/copy` | POST | no |
| Ollama | `/api/delete` | DELETE | no |
| Ollama | `/api/create` | POST | no |
| Ollama | `/api/search` | POST | no |
| Ollama | `/api/ps` | GET | no |
| Ollama | `/api/version` | GET | no |
| health | `/health` | GET | no |
| health | `/health/ready` | GET | no |
| health | `/metrics` | GET | no |

## Talk to it — three SDK examples

OpenAI Python SDK:

```python
from openai import OpenAI
c = OpenAI(api_key="not-used", base_url="http://127.0.0.1:8080/v1")
print(c.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role": "user", "content": "Hi."}],
).choices[0].message.content)
```

Anthropic Python SDK:

```python
from anthropic import Anthropic
a = Anthropic(api_key="not-used", base_url="http://127.0.0.1:8080")
print(a.messages.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    max_tokens=64,
    messages=[{"role": "user", "content": "Hi."}],
).content[0].text)
```

Ollama-compatible CLI:

```sh
OLLAMA_HOST=http://127.0.0.1:8080 ollama list
OLLAMA_HOST=http://127.0.0.1:8080 ollama run llama3 "Hi."
```

Claude Code as a local backend:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 \
ANTHROPIC_AUTH_TOKEN=not-used \
  claude
```

## Structured output

```sh
# OpenAI shape
curl -sN http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "messages": [{"role":"user","content":"a person named Alice, age 30, JSON only"}],
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "person",
        "schema": {
          "type": "object",
          "properties": {
            "name": {"type": "string"},
            "age":  {"type": "integer"}
          },
          "required": ["name", "age"]
        }
      }
    }
  }'

# Ollama shape
curl -sN http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{"model":"qwen2.5","prompt":"alice is 30","format":"json"}'
```

Either request installs a GBNF over the sampler so the model can
only emit tokens consistent with the schema.

## Configure

`config/sys.config` (defaults shown):

```erlang
{erllama_server, [
  {port,                       8080},
  {ip,                         {0,0,0,0}},
  {num_acceptors,              100},
  %% Auto-eviction TTL per model when active requests drop to zero.
  %% Per-request `keep_alive` overrides this on /api/* endpoints.
  {keep_alive_default_ms,      300000},
  %% Cap on context size pulled from GGUF (models advertising 128k
  %% don't auto-pin tens of GB of KV cache).
  {max_context_size,           4096},
  %% Cowboy idle_timeout: 30 min to survive long downloads / loads.
  {idle_timeout_ms,            1800000},
  %% Pull a model on demand if it's not in the registry yet.
  {auto_pull,                  false},
  %% Where blobs + manifests live.
  %% {model_cache_dir, "/srv/erllama_server/cache"},
  {model_aliases, #{
    <<"gpt-4o">>        => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>,
    <<"claude-sonnet">> => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>
  }},
  {pool_exhausted_policy,
     {queue, #{concurrency => 1, depth => 100, timeout_ms => 30000}}},
  {model_load_policy,          on_demand},
  {max_request_body_bytes,     1048576},
  {max_embedding_inputs,       256},
  {cors,                       off},
  {request_id_header,          <<"x-request-id">>}
]}.
```

CORS:

```erlang
{cors, #{
  allow_origins     => <<"*">>,
  allow_credentials => false,
  allow_methods     => <<"GET, POST, OPTIONS">>,
  allow_headers     => <<"authorization, content-type, x-request-id">>,
  max_age           => 600
}}
```

## Model resolution

The `model` field in every request is run through one shared
rewrite step before the loader touches it:

```
client request -> model_aliases lookup -> registry manifest
   "claude-sonnet-4-5"  ─►  "Qwen/...:main"  ─►  manifests/Qwen:.../main.json
```

`resolve_model/1` does an alias-or-identity `maps:get/3`, so any
id missing from `model_aliases` falls through unchanged. The
result has to exist in the registry (`erllama list`); otherwise
the request fails with `404 model_not_found` unless
`auto_pull = true`, in which case the loader pulls it from the
default Ollama-style registry first.

Three common shapes:

```sh
# 1) Pass the registry id directly. Works in every SDK.
curl -sN http://127.0.0.1:8080/v1/chat/completions \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct-GGUF:main", ...}'

# 2) Alias an SDK's default id so it Just Works without flags.
#    In sys.config:
{model_aliases, #{
  <<"claude-sonnet-4-5">> => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>,
  <<"gpt-4o-mini">>       => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>
}}

# 3) Hot-update aliases from a running shell, no restart needed.
1> erllama_server_config:set_aliases(
1>   #{<<"claude-sonnet-4-5">> => <<"Qwen/...:main">>}).
```

Tag-less ids resolve to `:latest`. The CLI prints the canonical
form: `erllama list` for what's installed, `erllama show <id>`
for the resolved manifest.

See [`guides/clients.md`](guides/clients.md#model-resolution-flow)
for the per-SDK breakdown.

## Authentication for `pull`

HuggingFace gated repos: set `HF_TOKEN` before starting the server.

```sh
export HF_TOKEN=hf_xxx
_build/default/rel/erllama_server/bin/erllama_server daemon
```

Plain HTTPS sources do not currently support per-call basic auth or
custom headers; `curl` once and pass the resulting path through
`file://` instead.

## Architecture

```
erllama_server_sup (rest_for_one)
├── erllama_server_registry         via callback for {queue, ModelId}
├── erllama_server_config           aliases + policy + persistent_term
├── erllama_server_disk_cache       KV cache tier (erllama_cache_disk_srv)
├── erllama_server_loaders_sup      per-model loader processes
├── erllama_server_queues_sup       per-model semaphore queues
├── erllama_server_fetch_sup        download workers
├── erllama_server_fetch_srv        dedupe + progress fan-out
├── erllama_server_keepalive        per-model TTL eviction
└── erllama_server_listener_mon     Cowboy listener + restart watch
```

Each request:

1. **Fast phase** (in `init/2`): read body, decode JSON, translate to
   `#erllama_request{}`, resolve alias. Failures land as JSON 4xx via
   `cowboy_req:reply/4` before the handler enters `cowboy_loop`.
2. Spawn a linked **pipeline worker** that runs the slow phase:
   `ensure_loaded_async` -> `apply_chat_template` (or `tokenize` for
   legacy completions) -> grammar build -> queue acquire ->
   `erllama:infer/4`. Progress messages flow back to the handler.
3. **Streaming**: handler stays in `cowboy_loop`, receives
   `{erllama_token, ...}` messages, emits SSE / NDJSON.
4. **Non-streaming**: same handler, accumulates tokens, replies once.
5. **Cancel-on-disconnect**: TCP close triggers `terminate/3`, which
   calls `erllama:cancel/1`, releases the queue slot, kills the
   pipeline worker.

## Test

```sh
rebar3 fmt --check
rebar3 lint
rebar3 xref
rebar3 dialyzer
rebar3 eunit          # 127 cases
rebar3 escriptize     # required by CLI suites
rebar3 ct             # 106 cases (6 skipped without a real GGUF)
```

The real-model CT suite (`erllama_server_real_model_SUITE`) is
gated on `LLAMA_TEST_MODEL` pointing at a GGUF file.

## Links

- Documentation: <https://erllama.github.io/erllama_server/>
- Source: <https://github.com/erllama/erllama_server>
- OpenAPI spec: [`openapi.yaml`](openapi.yaml)
- Changelog: [`CHANGELOG.md`](CHANGELOG.md)
- Issue tracker: <https://github.com/erllama/erllama_server/issues>

## License

MIT.
