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
  claude-code
```

Set an alias in `sys.config` if you want a specific model id
to map to your locally-pulled GGUF:

```erlang
{model_aliases, #{
  <<"claude-sonnet">> => <<"Qwen/Qwen2.5-7B-Instruct-GGUF:main">>
}}
```
