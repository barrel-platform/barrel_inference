"""Anthropic SDK against /v1/messages."""
# pip install anthropic
import os
from anthropic import Anthropic

a = Anthropic(
    api_key="not-used",
    base_url=os.environ.get("BARREL_INFERENCE_HOST", "http://127.0.0.1:8080"),
)
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct-GGUF:main")

# Non-streaming
m = a.messages.create(
    model=MODEL,
    max_tokens=32,
    messages=[{"role": "user", "content": "Hi."}],
)
print("non-streaming:", m.content[0].text)

# Streaming
print("\nstreaming:")
with a.messages.stream(
    model=MODEL,
    max_tokens=32,
    messages=[{"role": "user", "content": "Count to three."}],
) as s:
    for delta in s.text_stream:
        print(delta, end="", flush=True)
print()
