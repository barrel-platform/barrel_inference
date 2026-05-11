"""Strict JSON Schema via OpenAI response_format."""
# pip install openai pydantic
import os
from openai import OpenAI
from pydantic import BaseModel

c = OpenAI(
    api_key="not-used",
    base_url=os.environ.get("ERLLAMA_HOST", "http://127.0.0.1:8080") + "/v1",
)
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct-GGUF:main")


class Person(BaseModel):
    name: str
    age: int


resp = c.chat.completions.create(
    model=MODEL,
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
raw = resp.choices[0].message.content
print("raw:", raw)
print("parsed:", Person.model_validate_json(raw))
