# erllama_server

OpenAI- and Anthropic-compatible HTTP server on top of
[erllama](https://github.com/erllama/erllama). Drop-in for clients
that already speak the OpenAI Python SDK, the Anthropic SDK, or
Ollama-style tools, but running locally against any GGUF model
llama.cpp can load.

## What it gives you

- `POST /v1/chat/completions` (OpenAI), streaming and non-streaming
- `POST /v1/completions` (OpenAI legacy text completions)
- `POST /v1/messages` (Anthropic, used by Claude Code as a local backend)
- `POST /v1/embeddings`
- `GET  /v1/models[/:id]` with alias passthrough
- `GET  /health` and `GET /health/ready`
- `GET  /metrics` (Prometheus text format via
  [`instrument`](https://github.com/benoitc/instrument))
- Tool calls via grammar-constrained sampling
- Per-model FIFO admission queue with `pool_exhausted` 429s
- CORS preflight + headers (off by default)
- `X-Request-ID` echo

## Run

```sh
rebar3 release -d
_build/default/rel/erllama_server/bin/erllama_server foreground
```

The default `config/sys.config` boots with no models loaded; aliases
and policy live there.

## Test

```sh
rebar3 ct        # 61 cases, no GGUF needed
rebar3 dialyzer
rebar3 lint
rebar3 fmt --check
```

## Configure

`config/sys.config`:

```erlang
{erllama_server, [
  {port,          8080},
  {ip,            {0,0,0,0}},
  {model_aliases, #{
    <<"gpt-4o">>        => <<"llama3-8b-q4">>,
    <<"claude-sonnet">> => <<"deepseek-v4">>
  }},
  {pool_exhausted_policy,
     {queue, #{concurrency => 1, depth => 100, timeout_ms => 30000}}},
  {model_load_policy, on_demand},
  {max_messages,      1024},
  {max_tools,         128},
  {cors,              off},
  {request_id_header, <<"x-request-id">>}
]}.
```

CORS, when enabled, is a map:

```erlang
{cors, #{
  allow_origins     => <<"*">>,
  allow_credentials => false,
  allow_methods     => <<"GET, POST, OPTIONS">>,
  allow_headers     => <<"authorization, content-type, x-request-id">>,
  max_age           => 600
}}
```

## Talk to it

OpenAI Python SDK:

```python
from openai import OpenAI
c = OpenAI(api_key="not-used", base_url="http://127.0.0.1:8080/v1")
print(c.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hi."}]
).choices[0].message.content)
```

Anthropic SDK:

```python
from anthropic import Anthropic
a = Anthropic(api_key="not-used", base_url="http://127.0.0.1:8080")
print(a.messages.create(
    model="claude-sonnet",
    max_tokens=64,
    messages=[{"role": "user", "content": "Hi."}]
).content[0].text)
```

Claude Code local backend:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 \
ANTHROPIC_AUTH_TOKEN=not-used \
claude-code
```

## Architecture

```
erllama_server_sup (rest_for_one)
├── erllama_server_registry      via callback for {queue, ModelId}
├── erllama_server_config        aliases + load policy + persistent_term
├── erllama_server_loaders_sup   per-model loader processes
├── erllama_server_queues_sup    per-model semaphore queues
└── erllama_server_listener_mon  Cowboy listener + restart watch
```

Each request lifecycle:

1. **Fast phase** (in `init/2`): read body, decode JSON, translate to
   `#erllama_request{}`, resolve alias.
2. Spawn a linked **pipeline worker** that runs the slow phase:
   `ensure_loaded` → `apply_chat_template` (or `tokenize` for legacy
   completions) → grammar build → queue acquire → `erllama:infer/4`.
3. **Streaming**: handler sits in `cowboy_loop`, receives
   `{erllama_token, ...}` messages and emits SSE chunks. Tool-call
   mode buffers grammar-mode JSON and emits one final tool_calls /
   tool_use frame.
4. **Non-streaming**: same handler, accumulates tokens into a buffer,
   replies once on `erllama_done`.
5. **Cancel-on-disconnect**: Cowboy fires `terminate/3` on TCP close,
   which calls `erllama:cancel/1`, releases the queue slot, kills the
   pipeline worker.

## Limits in v0.1

- Tool-call `arguments` is buffered and emitted as one chunk, not
  streamed byte-by-byte. (Both OpenAI and Anthropic SDKs accept
  this.)
- Embeddings loops over array input sequentially. An
  `erllama:embed_batch/2` call would replace the loop with a single
  batched decode.
- Multi-modal content blocks (image/audio) are out of scope.

## License

MIT
