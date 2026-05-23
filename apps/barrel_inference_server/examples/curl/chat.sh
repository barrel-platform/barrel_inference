#!/usr/bin/env bash
# OpenAI /v1/chat/completions (streaming + non-streaming).
set -euo pipefail
HOST="${ERLLAMA_HOST:-http://127.0.0.1:8080}"
MODEL="${MODEL:-Qwen/Qwen2.5-7B-Instruct-GGUF:main}"

echo "==> non-streaming"
curl -fsS -X POST "$HOST/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "$(cat <<JSON
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "Say hi briefly."}],
  "max_tokens": 16
}
JSON
)" | python3 -m json.tool

echo
echo "==> streaming"
curl -fsSN -X POST "$HOST/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "$(cat <<JSON
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "Count to five."}],
  "stream": true,
  "max_tokens": 32
}
JSON
)"
echo
