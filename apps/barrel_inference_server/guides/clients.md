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
