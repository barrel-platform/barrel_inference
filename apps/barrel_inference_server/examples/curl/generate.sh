#!/usr/bin/env bash
# Ollama /api/generate: streaming, preload, unload.
set -euo pipefail
HOST="${ERLLAMA_HOST:-http://127.0.0.1:8080}"
MODEL="${MODEL:-Qwen/Qwen2.5-7B-Instruct-GGUF:main}"

echo "==> streaming generate"
curl -fsSN -X POST "$HOST/api/generate" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hi briefly.\",\"options\":{\"num_predict\":12}}"
echo

echo "==> preload (empty prompt)"
curl -fsS -X POST "$HOST/api/generate" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"\"}" | python3 -m json.tool

echo
echo "==> unload (empty prompt + keep_alive 0)"
curl -fsS -X POST "$HOST/api/generate" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"\",\"keep_alive\":0}" | python3 -m json.tool
