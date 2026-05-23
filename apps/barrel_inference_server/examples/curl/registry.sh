#!/usr/bin/env bash
# Walk a model through its full lifecycle: pull -> list -> show ->
# copy -> ps -> unload -> delete. Reports each response shape.
set -euo pipefail
HOST="${BARREL_INFERENCE_HOST:-http://127.0.0.1:8080}"
SPEC="${SPEC:-hf://Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q3_k_m.gguf}"
NAME="${NAME:-Qwen/Qwen2.5-7B-Instruct-GGUF:main}"
ALIAS="${ALIAS:-qwen7b:latest}"

step()  { echo; echo "==> $*"; }
api()   { curl -fsS -H 'content-type: application/json' "$@"; }

step "pull (streaming NDJSON, pipe through grep -E 'status' for one line per phase)"
api -X POST "$HOST/api/pull" -d "{\"name\":\"$SPEC\"}" | grep -E '"status"' | head -10

step "list (registered models)"
api "$HOST/api/tags" | python3 -m json.tool

step "show manifest"
api -X POST "$HOST/api/show" -d "{\"name\":\"$NAME\"}" | python3 -m json.tool

step "copy -> alias"
api -X POST "$HOST/api/copy" -d "{\"source\":\"$NAME\",\"destination\":\"$ALIAS\"}"
echo "(copied)"

step "preload to land it in /api/ps"
api -X POST "$HOST/api/generate" -d "{\"model\":\"$NAME\",\"prompt\":\"\"}" >/dev/null

step "ps (currently loaded)"
api "$HOST/api/ps" | python3 -m json.tool

step "unload now"
api -X POST "$HOST/api/generate" -d "{\"model\":\"$NAME\",\"prompt\":\"\",\"keep_alive\":0}" >/dev/null
api "$HOST/api/ps" | python3 -m json.tool

step "delete alias"
curl -fsS -X DELETE -H 'content-type: application/json' \
  "$HOST/api/delete" -d "{\"name\":\"$ALIAS\"}"
echo "(deleted)"
