# SDK + client examples

Runnable snippets pointing at a local daemon at
`http://127.0.0.1:8080`. Replace the model id with whatever you
have pulled (`erllama list` to check).

## Python: OpenAI SDK

```python
# pip install openai
from openai import OpenAI

c = OpenAI(api_key="not-used", base_url="http://127.0.0.1:8080/v1")
print(c.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role": "user", "content": "Say hi briefly."}],
).choices[0].message.content)
```

Streaming:

```python
stream = c.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role": "user", "content": "Count to five."}],
    stream=True,
)
for chunk in stream:
    delta = chunk.choices[0].delta.content or ""
    print(delta, end="", flush=True)
print()
```

JSON Schema constrained output:

```python
from pydantic import BaseModel

class Person(BaseModel):
    name: str
    age: int

resp = c.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role": "user", "content": "Alice, age 30"}],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "person",
            "schema": Person.model_json_schema(),
            "strict": True,
        },
    },
)
person = Person.model_validate_json(resp.choices[0].message.content)
print(person)
```

Tool / function calling:

```python
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Look up the weather in a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}]
resp = c.chat.completions.create(
    model="qwen7b",
    messages=[{"role": "user", "content": "weather in Paris?"}],
    tools=tools,
    tool_choice="auto",
)
print(resp.choices[0].message.tool_calls)
```

Embeddings:

```python
vec = c.embeddings.create(model="nomic-embed-text", input="hello").data[0].embedding
print(len(vec))
```

## Python: Anthropic SDK

```python
# pip install anthropic
from anthropic import Anthropic

a = Anthropic(api_key="not-used", base_url="http://127.0.0.1:8080")
m = a.messages.create(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    max_tokens=64,
    messages=[{"role": "user", "content": "Hi."}],
)
print(m.content[0].text)
```

Streaming with named events:

```python
with a.messages.stream(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    max_tokens=32,
    messages=[{"role": "user", "content": "Count to three."}],
) as stream:
    for delta in stream.text_stream:
        print(delta, end="", flush=True)
    print()
```

## Python: ollama package

```python
# pip install ollama
import ollama

c = ollama.Client(host="http://127.0.0.1:8080")
print(c.generate(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    prompt="Say hi briefly.",
)["response"])

# Streaming
for part in c.generate(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    prompt="Count to five.",
    stream=True,
):
    print(part["response"], end="", flush=True)
print()

# Chat
print(c.chat(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages=[{"role":"user","content":"Hi."}],
)["message"]["content"])

# Preload
c.generate(model="Qwen/Qwen2.5-7B-Instruct-GGUF:main", prompt="")
print(c.ps())  # ollama 0.4+: list currently-loaded models
```

## Raw HTTP from Python (no SDK)

```python
import json, urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:8080/api/generate",
    data=json.dumps({
        "model": "qwen7b",
        "prompt": "Say hi briefly.",
        "stream": False,
    }).encode(),
    headers={"content-type": "application/json"},
)
with urllib.request.urlopen(req) as r:
    print(json.loads(r.read())["response"])
```

## JavaScript (browser / Node)

```js
// Non-streaming (Node 18+ or browser)
const r = await fetch("http://127.0.0.1:8080/v1/chat/completions", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: "Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    messages: [{ role: "user", content: "Hi" }],
  }),
});
const j = await r.json();
console.log(j.choices[0].message.content);
```

Streaming SSE:

```js
const resp = await fetch("http://127.0.0.1:8080/v1/chat/completions", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: "qwen7b",
    messages: [{ role: "user", content: "Count to 5." }],
    stream: true,
  }),
});

const reader = resp.body.getReader();
const decoder = new TextDecoder();
let buf = "";
for (;;) {
  const { done, value } = await reader.read();
  if (done) break;
  buf += decoder.decode(value, { stream: true });
  let nl;
  while ((nl = buf.indexOf("\n\n")) !== -1) {
    const frame = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 2);
    if (!frame.startsWith("data: ")) continue;
    const payload = frame.slice(6);
    if (payload === "[DONE]") return;
    const chunk = JSON.parse(payload);
    process.stdout.write(chunk.choices[0].delta.content ?? "");
  }
}
```

NDJSON (Ollama `/api/generate` streaming):

```js
const resp = await fetch("http://127.0.0.1:8080/api/generate", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ model: "qwen7b", prompt: "Say hi briefly." }),
});
const reader = resp.body.getReader();
const decoder = new TextDecoder();
let buf = "";
for (;;) {
  const { done, value } = await reader.read();
  if (done) break;
  buf += decoder.decode(value, { stream: true });
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    if (!line) continue;
    const j = JSON.parse(line);
    if (j.done) { console.log(); console.log(`done_reason=${j.done_reason}`); break; }
    process.stdout.write(j.response);
  }
}
```

## Bundled `erllama` CLI

The escript ships with the release:

```sh
erllama pull <name>                 pull a model into the registry
erllama list                        list registered models
erllama ps                          list currently-loaded models
erllama show <name>                 print one manifest
erllama rm <name>                   remove a manifest
erllama copy <src> <dst>            alias under a new name:tag
erllama search <query>              search HF / Ollama
erllama run <name> [prompt..]       stream a chat completion
erllama embed <name> <text..>       compute an embedding vector
erllama unload <name>               evict a model from memory now
erllama version                     print the server version
erllama help
```

Target a non-default host via `ERLLAMA_HOST`:

```sh
ERLLAMA_HOST=http://gpu.lan:8080 erllama list
```

## LangChain / LiteLLM

Point at the OpenAI-compatible base URL:

```python
# pip install langchain-openai
from langchain_openai import ChatOpenAI
chat = ChatOpenAI(
    model="Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    base_url="http://127.0.0.1:8080/v1",
    api_key="not-used",
)
print(chat.invoke("Hi.").content)
```

```python
# pip install litellm
import litellm
print(litellm.completion(
    model="openai/Qwen/Qwen2.5-7B-Instruct-GGUF:main",
    api_base="http://127.0.0.1:8080/v1",
    api_key="not-used",
    messages=[{"role": "user", "content": "Hi."}],
).choices[0].message.content)
```

## Claude Code as a local backend

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 \
ANTHROPIC_AUTH_TOKEN=not-used \
  claude --model qwen-sonnet
```

Claude Code sends the model id in every `/v1/messages` request.
`erllama_server` then runs that id through alias resolution and
looks up the result in the manifest registry. Two ways to wire it:

**1. Pass a local id directly.** `claude --model <registry-id>` or
the `ANTHROPIC_MODEL` env var. The id has to match something in
`erllama list`:

```sh
erllama list
# NAME                                       SIZE   MODIFIED
# Qwen/Qwen2.5-7B-Instruct-GGUF:main         4.4G   2026-05-11

claude --model "Qwen/Qwen2.5-7B-Instruct-GGUF:main"
```

**2. Define an alias.** Add to `config/sys.config` and restart:

```erlang
{model_aliases, #{
  <<"qwen-sonnet">>               => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>,
  <<"claude-sonnet-4-5">>         => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>,
  <<"claude-opus-4-7">>           => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>
}}
```

After that, `claude --model qwen-sonnet` works, and if you alias
the upstream Claude ids themselves, Claude Code's own defaults
will route to your local model without flags. Aliases are pure
rewrite: `claude-sonnet-4-5` -> `Qwen/...:main` -> registry
lookup. Unknown ids fall through to a registry lookup as-is, so
the registry name itself always works.

### End-to-end walkthrough

From clone to a working Claude Code session against your laptop's
GPU. Skips steps already done in the [quickstart](quickstart.md).

#### 1. Build and put both binaries on PATH

```sh
cd erllama_server
rebar3 release
export PATH=$PWD/_build/default/rel/erllama_server/bin:$PATH
```

`erllama_server` (daemon) and `erllama` (CLI) are now both
callable.

#### 2. Configure aliases + the `n_seq_max` gotcha

Edit `config/sys.config`:

```erlang
[
 {erllama_server, [
   {port, 8080},
   {model_aliases, #{
     %% Claude Code's current default trio.
     <<"claude-opus-4-7">>            => <<"local-coder">>,
     <<"claude-sonnet-4-5">>          => <<"local-coder">>,
     <<"claude-haiku-4-5">>           => <<"local-coder">>,
     %% Older Claude ids some SDKs still cache.
     <<"claude-3-5-sonnet-20241022">> => <<"local-coder">>,
     <<"claude-3-5-haiku-20241022">>  => <<"local-coder">>
   }},
   {pool_exhausted_policy,
     {queue, #{concurrency => 2, depth => 4, timeout_ms => 30000}}}
 ]}
].
```

`concurrency => 2` here is paired with the model's
`context_opts.n_seq_max => 4` (see below). Sticky-seq pins one
engine seq_id per active conversation, so `n_seq_max=1` (the
engine default) deadlocks the moment two sessions overlap.

#### 3. Pull a model

Claude Code talks to real coding workloads, so you want at least
a 7B coder-tuned model. Qwen2.5-Coder-7B is a good first target:

```sh
erllama pull hf://Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/qwen2.5-coder-7b-instruct-q4_k_m.gguf
erllama copy "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:main" "local-coder:main"
```

If you want tool-call exact-replay (recommended for repeat-loop
agents like Claude Code), the manifest needs `tool_call_markers`
and `tool_call_format` declared in its `loader` section. For
Qwen-family models the default registry already has `qwen-xml`;
you just need the markers. Edit the manifest:

```sh
MANIFEST="$(find ~/Library/Caches/erllama_server/manifests \
  -name '*.json' -path '*local-coder*' | head -1)"
# add to the JSON's "loader" object:
#   "tool_call_markers": {"start":"<tool_call>","end":"</tool_call>"},
#   "tool_call_format": "qwen-xml",
#   "context_opts": {"n_seq_max": 4}
```

(The cache root and exact path depend on your platform; check
`erllama show local-coder:main` to confirm where it landed.)

#### 4. Boot the daemon

```sh
erllama_server daemon
curl -fsS http://127.0.0.1:8080/health     # -> {"status":"ok"}
curl -fsS http://127.0.0.1:8080/v1/models  # confirms `local-coder` + aliases
```

#### 5. Point Claude Code at it

Two env vars and Claude Code uses your daemon instead of
Anthropic's hosted API:

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:8080
export ANTHROPIC_AUTH_TOKEN=not-used   # any non-empty value
```

Then in any project directory:

```sh
claude "list the files in this repo and summarise the layout"
```

Claude Code sends a `claude-opus-4-7` (or similar) request; the
daemon's alias map routes it to `local-coder:main`; Qwen2.5-Coder
generates the response; the Anthropic SSE stream comes back to
Claude Code. Subsequent turns on the same conversation reuse the
prior KV state via the v0.6 `continue/3` path.

#### 6. Watch what's happening

```sh
# Daemon log (structured per-request lines + access log)
tail -f _build/default/rel/erllama_server/log/erlang.log.*

# Prometheus counters
curl -sS http://127.0.0.1:8080/metrics | \
  grep -E 'cache_hits_total|active_streams|tool_replay_lookups'

# Loaded models
erllama ps
```

The `erllama_cache_hits_total{kind="continuation"}` counter
climbs on every multi-turn continuation — that's the v0.6 path
firing.

#### 7. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| 529 with `retry-after` | Two concurrent admits on the same session — Claude Code occasionally fires parallel asks; SDKs retry. A spike means `n_seq_max` is too low. |
| 504 `queue_timeout` after a few turns | A sticky session pinned a seq and no spare seq_ids are left; bump `loader.context_opts.n_seq_max` to 4+. |
| Garbage tokens on turn 2+ | Model's chat template re-renders prior turns differently across turns; the continuation suffix doesn't line up against the engine's stored prefix. Pick a model whose template is stable (run `multi_turn_cache_delta_profile` against it first). |
| Claude Code says "model not found" | The alias key in `sys.config` doesn't match the exact id Claude Code is sending. Check `curl http://127.0.0.1:8080/v1/models` and compare. |
| First load is slow | Cold-pull + GGUF mmap + Metal/CUDA init can be 20-30 s for a 7B Q4 on Apple Silicon. Warm reloads are sub-second. |

#### 8. Stop

```sh
erllama_server stop
```

### Multiple Claude models on one server

`model_aliases` is the mechanism for "Claude Code's model picker
should route to N different local models." Aliases are an
arbitrary `client-facing id -> registry id` map; nothing forces
multiple aliases to point at the same backend. Map each Claude id
your client knows about to whichever local model fits:

```erlang
{model_aliases, #{
  %% Claude's flagship -> your largest local model.
  <<"claude-opus-4-7">>            => <<"meta-llama/Llama-3.3-70B-Instruct-GGUF:q5_k_m">>,
  <<"claude-opus-4">>              => <<"meta-llama/Llama-3.3-70B-Instruct-GGUF:q5_k_m">>,
  %% Mid-tier -> a 7-14B coder.
  <<"claude-sonnet-4-5">>          => <<"Qwen/Qwen2.5-Coder-14B-Instruct-GGUF:main">>,
  <<"claude-3-5-sonnet-20241022">> => <<"Qwen/Qwen2.5-Coder-14B-Instruct-GGUF:main">>,
  %% Fast -> a small model that loads quickly.
  <<"claude-haiku-4-5">>           => <<"Qwen/Qwen2.5-3B-Instruct-GGUF:main">>,
  <<"claude-3-5-haiku-20241022">>  => <<"Qwen/Qwen2.5-3B-Instruct-GGUF:main">>
}}
```

Claude Code's UI then switches between these without code changes
on either side. Same goes for the API: a client passing
`"model": "claude-opus-4-7"` lands on the 70B; passing
`"claude-haiku-4-5"` lands on the 3B. The handler reads the model
from the body, runs `erllama_server_config:resolve_model/1`
(persistent_term-backed, single map lookup), and the rest of the
pipeline is identical regardless of which alias you matched.

A few practical patterns:

- **Pin Claude defaults to one model**: alias only the Claude ids
  Claude Code sends out of the box (current defaults are
  `claude-opus-4-7`, `claude-sonnet-4-5`, `claude-haiku-4-5`).
  Then users never need `--model` on the CLI.
- **Coding vs chat split**: alias `claude-sonnet-*` to a
  code-specialised local model (Qwen Coder, DeepSeek Coder) and
  `claude-opus-*` / `claude-haiku-*` to a general-purpose one.
- **Test multiple models without restart**: call
  `erllama_server_config:set_aliases/1` from a connected shell
  with the new map. Hot-reloads instantly; in-flight requests
  resolve against the snapshot they read at request time.
- **Mixed local-id / Claude-id traffic**: aliases are
  alias-or-identity. If the client sends a registry id directly
  it bypasses the map and goes straight to the registry.

The behaviour replaces what tools like `ds4` do (route Claude
Code's Anthropic API requests to local models): `erllama_server`
is that route, with the local registry + multi-tier KV cache
underneath.

### Per-model tool-call format

When a model emits tool calls between distinguishable delimiters
(qwen3 wraps JSON in `<tool_call>...</tool_call>`, DeepSeek-V3
uses fullwidth `<｜tool▁call▁begin｜>...<｜tool▁call▁end｜>`,
Llama 3.x uses `<|python_tag|>...<|eom_id|>`, Mistral v3 uses
`[TOOL_CALLS]`), declare the format in the model's manifest so
the server can capture the exact on-wire bytes:

```json
{
  "name": "Qwen/Qwen3-8B-Instruct-GGUF",
  "tag": "main",
  ...
  "loader": {
    "tool_call_markers": {
      "start": "<tool_call>",
      "end": "</tool_call>"
    },
    "tool_call_format": "qwen-xml"
  }
}
```

Five families ship in the default registry:

| Format name | Models | Body shape |
| --- | --- | --- |
| `qwen-xml` | Qwen3, Qwen2.5 | `<tool_call>{"name":..., "arguments":...}</tool_call>` |
| `dsml` | DeepSeek-V3, R1 | `<｜tool▁call▁begin｜>function<｜tool▁sep｜>NAME` + newline + fenced JSON + `<｜tool▁call▁end｜>` |
| `llama-python-tag` | Llama 3.1 / 3.2 / 3.3 | `<\|python_tag\|>{"name":..., "parameters":...}<\|eom_id\|>` |
| `mistral-tool-calls` | Mistral, Mixtral v3 | `[TOOL_CALLS][{"name":..., "arguments":...}]</s>` |
| `bare-json` | catch-all | `{"name":..., "arguments":...}` |

With both `tool_call_markers` and `tool_call_format` set, the
engine builds a deterministic greedy-on-syntax sampler for the
tool-call span and the server captures every `toolu_...` id's
exact bytes in a DETS-backed replay map. Operators that need a
format not in the default registry add one module + one map entry
under the `tool_call_formats` app env in `sys.config`:

```erlang
{tool_call_formats, #{
  <<"my-format">> => #{module => my_format_module}
}}
```

The module implements the `erllama_server_tool_format` behaviour:
`parse/1` turns `FullBin` into `#{name => Bin, arguments => Map}`,
`canonicalise/1` does the reverse. The registry merges
operator-supplied entries on top of the defaults, so qwen-xml
et al. stay available even when extending the map.

#### Replay-map persistence and TTL

The replay map persists across restarts under
`<model_cache_dir>/replay/replay.dets`. TTL defaults to 30 days
(`tool_replay_ttl_ms`); gc runs hourly
(`tool_replay_gc_interval_ms`). Override either if you want a
shorter retention window or a different cache root:

```erlang
{tool_replay_dir, "/var/lib/erllama_server/replay"},
{tool_replay_ttl_ms, 604800000},        %% 7 days
{tool_replay_gc_interval_ms, 600000}    %% 10 minutes
```

The `erllama_tool_replay_lookups_total{result="hit"|"miss"|"no_format"}`
counter (Prometheus `/metrics`) reports how often the replay map
hits on the render side - useful for verifying that turn-to-turn
byte stability is holding up across an SDK's serialisation choices.

### Sticky-seq KV reuse across turns

Multi-turn conversations benefit from keeping the prior turn's KV
cells alive on the model so the next turn truncates-and-prefills in
place instead of restoring from disk. The server derives a stable
`session_id` per request (no client coordination required) via:

1. `x-conversation-id` HTTP header (opt-in for SDK callers that pass
   `extra_headers`, or for proxies / gateways).
2. `metadata.user_id` from the Anthropic body (Claude Code sends
   this natively as a per-user stable string).
3. `base64(sha256(model || first_user_message_bytes))` fallback.

The derived id is forwarded to `erllama:infer/4` on
`Params.session_id`. The next request on the same session reuses
the live KV cells; concurrent admits on the same session return
`sticky_busy` mapped to 503 with `retry-after` (529 on
`/v1/messages`).

**Operational gotcha — `n_seq_max`**

The engine pins the seq_id to its session for the lifetime of the
conversation. With the default `context_opts.n_seq_max = 1`, that
single seq is locked to the first session and any **other** session
deadlocks on admission. Operators must declare a higher seq count on
the model's load config:

```json
{
  "name": "Qwen/Qwen3-8B-Instruct-GGUF",
  ...
  "loader": {
    "context_opts": { "n_seq_max": 4 }
  }
}
```

A reasonable rule of thumb: set `n_seq_max` to match the per-model
queue `concurrency`, or higher if you expect concurrent sessions
from the same model. Cleanly-completed turns leave the session
pinned for the next turn; only mid-flight cancels free the seq.

**Continuation path (`erllama:continue/3`)**

Many chat templates render the leading turns *differently* in a
multi-turn context (different role markers, system-prefix
formatting). The engine's prefix-equality check on the `sticky`
path is byte-exact; when bytes diverge, it falls back to cold
admit and you pay full prefill per turn. To work around this,
the server uses erllama 0.6's `continue/3` primitive: after each
turn the engine-reported `committed_tokens` count is cached
server-side, and the next turn's pipeline slices the rendered
prompt at that boundary and asks the engine to prefill only the
tail.

Empirical impact (TinyLlama-1.1B, three-turn conversation with a
stable `x-conversation-id`):

| Turn | input | output | cache_read | cache_creation |
| --- | --- | --- | --- | --- |
| 1 | 21 | 32 | 0 | 53 |
| 2 | 73 | 32 | 53 | 52 |
| 3 | 125 | 32 | 105 | 52 |

Every turn after the first reuses the predecessor's entire
committed state. `cache_creation` collapses to the new tail
plus the generated output.

**Risk** — the slice is optimistic. `continue/3` doesn't verify
the suffix; if a model's chat template re-renders prior turns
differently, the engine prefills tokens that don't belong on
top of the stored prefix and the model emits garbage. Stats
report `cache_hit_kind = continuation` on this path, which
makes the failure mode diagnosable. Operators should run the
`multi_turn_cache_delta_profile/1` CT case against their
production model before relying on continuation — the test
asserts `cache_read > 0` on turn 2, which only passes when the
chat template's render is stable across turns.

```bash
LLAMA_TEST_MODEL=/path/to/model.gguf rebar3 ct \
  --suite=erllama_server_real_model_SUITE \
  --case=multi_turn_cache_delta_profile
```

### Optional API-key allowlist

By default `/v1/messages` does not validate `x-api-key`, which
matches the public Claude Code default of sending the literal
string `not-used` (or `ANTHROPIC_AUTH_TOKEN` if set). For
deployments behind a public address, set an allowlist:

```erlang
{anthropic_api_keys, [
  <<"sk-erllama-alice-…">>,
  <<"sk-erllama-bob-…">>
]}
```

Requests with `x-api-key` not in the list get
`401 authentication_error` in the standard Anthropic envelope.
Leave empty (default) for trusted local use.

### Big requests and the 32 MB ceiling

Claude Code's HTTP client refuses to send any request body larger
than 32 MB. With many MCP servers connected, the system prompt +
tool definitions alone can approach that on every turn. The server
accepts up to 32 MB by default (`max_request_body_bytes` in
`sys.config`); the ceiling lives in the client.

If you see `Request too large (max 32MB)` in your Claude Code
terminal, the only fix is to **reduce what Claude Code sends**:

- Disconnect MCP servers you aren't using (`claude mcp remove …`).
- Shorten `~/.claude/CLAUDE.md`.
- Trim project-level `CLAUDE.md` content.

Server-side caching helps with speed and cost, not upload size:

- erllama's **KV cache** (RAM/ramfile/disk tiered) hits when the
  prompt prefix repeats across turns, so the second turn skips
  prefill server-side. Already enabled.
- **Anthropic prompt caching** markers (`cache_control: {type:
  "ephemeral"}` on system / tools / message blocks) are recognised
  and reported back in `usage.cache_creation_input_tokens` /
  `usage.cache_read_input_tokens`. Claude Code attaches these
  automatically; you'll see hits on the second turn even when the
  full body is shipped every time.

What neither cache can do today: reduce client→server bytes. That
needs a non-standard session API the client also implements; not
on the roadmap until SDKs agree on one.

## Model resolution flow

Every API family is identical here. The handler:

1. Reads the `model` field from the request body (OpenAI / Ollama)
   or path/body (Anthropic `/v1/messages`).
2. Calls `erllama_server_config:resolve_model/1`. This is a
   one-line `maps:get/3` over `model_aliases` with the requested
   id as the default, so aliases are an alias-or-identity
   passthrough.
3. Calls `erllama_server_models:get/1` with the resolved id. If
   the registry has no manifest under that name, the request
   fails with `404 model_not_found`, unless `auto_pull = true` in
   which case the loader pulls it from the default registry first.

Practical consequences:

- Whatever the client sends in `model` reaches the registry,
  optionally rewritten by `model_aliases`. There is no
  per-API-family translation table.
- Tag-less ids resolve to `:latest`. `Qwen/Qwen2.5-7B-Instruct-GGUF`
  on the wire matches the manifest at
  `manifests/Qwen:Qwen2.5-7B-Instruct-GGUF/latest.json`.
- Aliases are hot-reloadable via
  `erllama_server_config:set_aliases/1` from a shell, no restart
  needed.
