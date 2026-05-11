# HTTP API reference (curl)

Every endpoint, one or two curl examples each. Server assumed at
`http://127.0.0.1:8080`.

> The canonical machine-readable spec lives at
> [`../openapi.yaml`](../openapi.yaml).

## Observability

```sh
# Liveness (always 200 once the listener is up)
curl -fsS http://127.0.0.1:8080/health

# Readiness (503 if no model is loaded yet under preloaded policy)
curl -fsS http://127.0.0.1:8080/health/ready

# Prometheus metrics (text format)
curl -fsS http://127.0.0.1:8080/metrics | head
```

## Ollama: registry

```sh
# Version
curl -sS http://127.0.0.1:8080/api/version
# -> {"version":"0.1.0"}

# Search HuggingFace + Ollama registries
curl -sS -X POST http://127.0.0.1:8080/api/search \
  -H 'content-type: application/json' \
  -d '{"query":"qwen","limit":3}'

# Pull (NDJSON progress; one JSON object per line)
curl -sN -X POST http://127.0.0.1:8080/api/pull \
  -H 'content-type: application/json' \
  -d '{"name":"hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf"}'

# List registered models
curl -sS http://127.0.0.1:8080/api/tags | jq .

# Show one manifest
curl -sS -X POST http://127.0.0.1:8080/api/show \
  -H 'content-type: application/json' \
  -d '{"name":"Qwen/Qwen2.5-7B-Instruct-GGUF:main"}' | jq .

# Currently-loaded (in memory) models
curl -sS http://127.0.0.1:8080/api/ps | jq .

# Copy (alias under a new name:tag)
curl -sS -X POST http://127.0.0.1:8080/api/copy \
  -H 'content-type: application/json' \
  -d '{"source":"Qwen/Qwen2.5-7B-Instruct-GGUF:main","destination":"qwen7b:latest"}'

# Delete (manifest only; blob is preserved for other aliases)
curl -sS -X DELETE http://127.0.0.1:8080/api/delete \
  -H 'content-type: application/json' \
  -d '{"name":"qwen7b:latest"}'

# Create from a Modelfile (FROM + PARAMETER + SYSTEM + TEMPLATE)
curl -sS -X POST http://127.0.0.1:8080/api/create \
  -H 'content-type: application/json' \
  -d @- <<'JSON'
{
  "name": "pirate:v1",
  "modelfile": "FROM Qwen/Qwen2.5-7B-Instruct-GGUF:main\nPARAMETER num_ctx 8192\nSYSTEM \"You are a pirate. Reply in pirate speak.\"\n"
}
JSON
```

## Ollama: inference

### `/api/generate`

```sh
# Streaming generate (default)
curl -sN -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "prompt": "say hello briefly"
  }'

# Non-streaming
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "prompt": "say hello",
    "stream": false,
    "options": {"num_predict": 8}
  }' | jq .

# Preload (empty prompt -> done_reason: "load", returns load_duration in ns)
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct-GGUF:main","prompt":""}' | jq .

# Unload (empty prompt + keep_alive 0 -> done_reason: "unload")
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct-GGUF:main","prompt":"","keep_alive":0}'

# Keep alive for an hour
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{"model":"qwen7b","prompt":"","keep_alive":"1h"}'

# Structured output: any JSON
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{"model":"qwen7b","prompt":"alice is 30","format":"json","stream":false}'

# Structured output: strict JSON Schema
curl -sS -X POST http://127.0.0.1:8080/api/generate \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen7b",
    "prompt": "name: Alice age: 30",
    "stream": false,
    "format": {
      "type": "object",
      "properties": {
        "name": {"type": "string"},
        "age":  {"type": "integer"}
      },
      "required": ["name","age"]
    }
  }'
```

### `/api/chat`

```sh
# Streaming chat
curl -sN -X POST http://127.0.0.1:8080/api/chat \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "messages": [{"role":"user","content":"reply with one word: hi"}],
    "options": {"num_predict": 4}
  }'

# Preload (empty messages array)
curl -sS -X POST http://127.0.0.1:8080/api/chat \
  -H 'content-type: application/json' \
  -d '{"model":"qwen7b","messages":[]}'
```

### `/api/embed` + `/api/embeddings`

```sh
# New shape (array of vectors)
curl -sS -X POST http://127.0.0.1:8080/api/embed \
  -H 'content-type: application/json' \
  -d '{"model":"nomic-embed-text","input":["alpha","beta"]}'

# Legacy single-prompt shape
curl -sS -X POST http://127.0.0.1:8080/api/embeddings \
  -H 'content-type: application/json' \
  -d '{"model":"nomic-embed-text","prompt":"alpha"}'
```

## OpenAI

```sh
# Models
curl -sS http://127.0.0.1:8080/v1/models | jq .

# Chat (streaming SSE)
curl -sN -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "messages": [{"role":"user","content":"say hi"}],
    "stream": true,
    "max_tokens": 20
  }'

# Chat (non-streaming)
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "messages": [{"role":"user","content":"say hi"}],
    "max_tokens": 20
  }'

# Structured output (JSON object)
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen7b",
    "messages": [{"role":"user","content":"JSON: alice is 30"}],
    "response_format": {"type": "json_object"}
  }'

# Strict JSON Schema (OpenAI structured outputs)
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen7b",
    "messages": [{"role":"user","content":"name=Alice age=30"}],
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "person",
        "schema": {
          "type": "object",
          "properties": {
            "name": {"type":"string"},
            "age":  {"type":"integer"}
          },
          "required": ["name","age"]
        }
      }
    }
  }'

# Tool / function calling
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen7b",
    "messages": [{"role":"user","content":"what is the weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Look up the weather in a city",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type":"string"}},
          "required": ["city"]
        }
      }
    }],
    "tool_choice": "auto"
  }'

# Embeddings
curl -sS -X POST http://127.0.0.1:8080/v1/embeddings \
  -H 'content-type: application/json' \
  -d '{"model":"nomic-embed-text","input":"hello"}'

# Legacy completions
curl -sS -X POST http://127.0.0.1:8080/v1/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen7b","prompt":"Once upon a time","max_tokens":20}'
```

## Anthropic

```sh
curl -sS -X POST http://127.0.0.1:8080/v1/messages \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "max_tokens": 64,
    "messages": [{"role":"user","content":"Hi."}]
  }'

# Streaming (Anthropic named SSE events)
curl -sN -X POST http://127.0.0.1:8080/v1/messages \
  -H 'content-type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    "max_tokens": 32,
    "messages": [{"role":"user","content":"Hi."}],
    "stream": true
  }'
```

## CORS preflight

```sh
curl -sS -X OPTIONS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Origin: https://example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type, authorization' \
  -i | head -20
```

Returns 204 + the configured `Access-Control-Allow-*` headers if
CORS is enabled in `sys.config`, otherwise the usual handler reply.

## Request ID

Echo your own ID via the `X-Request-ID` header — useful for
correlating client logs with server-side `instrument` traces:

```sh
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-request-id: my-trace-42' \
  -d '{"model":"qwen7b","messages":[{"role":"user","content":"hi"}]}' \
  -i | grep -i x-request-id
```
