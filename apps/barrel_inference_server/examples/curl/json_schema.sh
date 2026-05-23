#!/usr/bin/env bash
# Structured output: OpenAI response_format + Ollama format.
set -euo pipefail
HOST="${BARREL_INFERENCE_HOST:-http://127.0.0.1:8080}"
MODEL="${MODEL:-Qwen/Qwen2.5-7B-Instruct-GGUF:main}"

echo "==> OpenAI: json_schema (strict person object)"
curl -fsS -X POST "$HOST/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d @- <<JSON | python3 -m json.tool
{
  "model": "$MODEL",
  "messages": [{"role":"user","content":"name=Alice age=30 as JSON"}],
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
        "required": ["name","age"]
      }
    }
  }
}
JSON

echo
echo "==> Ollama: format=json"
curl -fsS -X POST "$HOST/api/generate" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"alice 30\",\"format\":\"json\",\"stream\":false}" \
  | python3 -m json.tool

echo
echo "==> Ollama: format=<schema>"
curl -fsS -X POST "$HOST/api/generate" \
  -H 'content-type: application/json' \
  -d @- <<JSON | python3 -m json.tool
{
  "model": "$MODEL",
  "prompt": "Alice is 30 years old",
  "stream": false,
  "format": {
    "type": "object",
    "properties": {
      "name": {"type": "string"},
      "age":  {"type": "integer"}
    },
    "required": ["name","age"]
  }
}
JSON
