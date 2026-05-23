"""Ollama Python package against barrel_inference_server.
Exercises generate, chat, preload, ps, embed."""
# pip install ollama
import os
import ollama

c = ollama.Client(host=os.environ.get("BARREL_INFERENCE_HOST", "http://127.0.0.1:8080"))
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct-GGUF:main")

# Generate
print("generate:", c.generate(model=MODEL, prompt="Say hi briefly.")["response"])

# Chat
print("chat:", c.chat(
    model=MODEL,
    messages=[{"role": "user", "content": "Hi."}],
)["message"]["content"])

# Preload
c.generate(model=MODEL, prompt="")
print("ps:", c.ps())

# Streaming generate
print("\nstreaming:")
for part in c.generate(model=MODEL, prompt="Count to five.", stream=True):
    print(part["response"], end="", flush=True)
print()
