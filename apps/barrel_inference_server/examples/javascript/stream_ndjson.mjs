// Streaming Ollama NDJSON from Node 18+ or the browser.
// Run: node examples/javascript/stream_ndjson.mjs

const HOST = process.env.BARREL_INFERENCE_HOST ?? "http://127.0.0.1:8080";
const MODEL = process.env.MODEL ?? "Qwen/Qwen2.5-7B-Instruct-GGUF:main";

const resp = await fetch(`${HOST}/api/generate`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: MODEL,
    prompt: "Say hi briefly.",
    options: { num_predict: 16 },
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
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const j = JSON.parse(line);
    if (j.done) {
      process.stdout.write("\n");
      console.log(`done_reason=${j.done_reason} eval=${j.eval_count} total=${j.total_duration}ns`);
      process.exit(0);
    }
    process.stdout.write(j.response ?? "");
  }
}
