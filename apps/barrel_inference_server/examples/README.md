# Examples

Standalone snippets that talk to a local `barrel_inference_server` daemon.
All examples honour `BARREL_INFERENCE_HOST` (default `http://127.0.0.1:8080`)
and `MODEL` (default `Qwen/Qwen2.5-7B-Instruct-GGUF:main`).

```
curl/                     bash scripts using curl
  chat.sh                 OpenAI /v1/chat/completions
  generate.sh             Ollama /api/generate (stream / preload / unload)
  json_schema.sh          structured output (OpenAI + Ollama)
  registry.sh             pull -> list -> show -> copy -> ps -> rm

python/                   needs: pip install openai anthropic ollama pydantic
  openai_chat.py
  openai_json_schema.py
  anthropic_messages.py
  ollama_full.py

javascript/               needs: Node 18+
  stream_sse.mjs          OpenAI streaming via fetch
  stream_ndjson.mjs       Ollama streaming via fetch
```

## Run

```sh
# Start the daemon first
_build/default/rel/barrel_inference_server/bin/barrel_inference_server daemon

# Pull a model
_build/default/bin/barrel-inference pull \
  hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf

# curl
bash examples/curl/chat.sh
bash examples/curl/generate.sh
bash examples/curl/json_schema.sh
bash examples/curl/registry.sh

# python
python examples/python/openai_chat.py
python examples/python/anthropic_messages.py
python examples/python/ollama_full.py

# javascript
node examples/javascript/stream_sse.mjs
node examples/javascript/stream_ndjson.mjs
```
