// Streaming OpenAI SSE from Node 18+ or the browser.
// Run: node examples/javascript/stream_sse.mjs

const HOST = process.env.ERLLAMA_HOST ?? "http://127.0.0.1:8080";
const MODEL = process.env.MODEL ?? "Qwen/Qwen2.5-7B-Instruct-GGUF:main";

const resp = await fetch(`${HOST}/v1/chat/completions`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: MODEL,
    messages: [{ role: "user", content: "Count to 5." }],
    stream: true,
    max_tokens: 32,
  }),
});

const reader = resp.body.getReader();
const decoder = new TextDecoder();
let buf = "";
for (;;) {
  const { done, value } = await reader.read();
  if (done) break;
  buf += decoder.decode(value, { stream: true });
  let i;
  while ((i = buf.indexOf("\n\n")) !== -1) {
    const frame = buf.slice(0, i).trim();
    buf = buf.slice(i + 2);
    if (!frame.startsWith("data: ")) continue;
    const payload = frame.slice(6);
    if (payload === "[DONE]") process.exit(0);
    const chunk = JSON.parse(payload);
    process.stdout.write(chunk.choices?.[0]?.delta?.content ?? "");
  }
}
process.stdout.write("\n");
