"""OpenAI Python SDK against a local erllama_server."""
# pip install openai
import os
from openai import OpenAI

c = OpenAI(
    api_key="not-used",
    base_url=os.environ.get("ERLLAMA_HOST", "http://127.0.0.1:8080") + "/v1",
)
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct-GGUF:main")

# Non-streaming
resp = c.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", "content": "Say hi briefly."}],
    max_tokens=16,
)
print("non-streaming:", resp.choices[0].message.content)

# Streaming
print("\nstreaming:")
for chunk in c.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", "content": "Count to five, comma-separated."}],
    stream=True,
    max_tokens=32,
):
    delta = chunk.choices[0].delta.content or ""
    print(delta, end="", flush=True)
print()
