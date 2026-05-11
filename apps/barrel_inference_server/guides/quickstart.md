# Quickstart

Five minutes from clone to first token.

## 1. Build

```sh
git clone https://github.com/benoitc/erllama_server.git
cd erllama_server
rebar3 release
rebar3 escriptize
```

`rebar3 release` pulls `erllama` and builds its `llama.cpp` NIF
(needs `cmake` + a C++17 toolchain). `rebar3 escriptize` produces
the `erllama` CLI at `_build/default/bin/erllama`.

## 2. Start the daemon

```sh
_build/default/rel/erllama_server/bin/erllama_server daemon
curl -fsS http://127.0.0.1:8080/health     # -> {"status":"ok"}
```

## 3. Pull a model

A Qwen 2.5 7B Q3_K_M (~3.8 GB, single-file) is a good first target
on a MacBook:

```sh
export PATH=$PWD/_build/default/bin:$PATH

erllama pull hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf
erllama list
# NAME                                SIZE     QUANT   FAMILY
# Qwen/Qwen2.5-7B-Instruct-GGUF:main  3.81 GB  q3_k_m  qwen
```

For HF gated repos: `export HF_TOKEN=hf_...` before starting the
daemon. For an Ollama-style short name use `erllama pull llama3`
which becomes `ollama://library/llama3:latest`.

## 4. Run inference

```sh
erllama run "Qwen/Qwen2.5-7B-Instruct-GGUF:main" "Say hello briefly"
```

First call loads the model (10-30 s for a 7B Q3 on Apple Silicon),
subsequent calls are warm.

## 5. Observe + manage

```sh
erllama ps             # what's loaded in memory now
erllama show "Qwen/Qwen2.5-7B-Instruct-GGUF:main"
erllama unload "Qwen/Qwen2.5-7B-Instruct-GGUF:main"
erllama version
erllama help
```

## Talking to it from SDKs

```python
# OpenAI Python SDK
from openai import OpenAI
c = OpenAI(api_key="not-used", base_url="http://127.0.0.1:8080/v1")
print(c.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role": "user", "content": "Hi"}],
).choices[0].message.content)
```

```python
# Anthropic Python SDK
from anthropic import Anthropic
a = Anthropic(api_key="not-used", base_url="http://127.0.0.1:8080")
print(a.messages.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    max_tokens=64,
    messages=[{"role": "user", "content": "Hi"}],
).content[0].text)
```

```sh
# Ollama-compatible CLI
OLLAMA_HOST=http://127.0.0.1:8080 ollama run llama3 "Hi"
```

Drop in your existing tooling: the server speaks all three.

## Stop the daemon

```sh
_build/default/rel/erllama_server/bin/erllama_server stop
```

## Next reads

- [`api.md`](api.md) — curl examples for every endpoint
- [`clients.md`](clients.md) — Python / JS / Erlang client snippets
- [`registry.md`](registry.md) — Modelfile + pull semantics
- [`fetching.md`](fetching.md) — URL syntax, cache layout, resume
- [`openapi.yaml`](openapi.md) — full OpenAPI 3.1 spec
