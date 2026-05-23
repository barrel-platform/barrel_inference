# Barrel Inference

OTP-native LLM inference for the BEAM: dirty NIFs over `llama.cpp`, supervised
per-model processes, and a token-exact tiered KV cache, with an
OpenAI/Anthropic/Ollama-compatible HTTP daemon on top.

Inference as a first-class OTP citizen, not a Python sidecar. The wedge is
supervision, per-model queues, and cancel-on-disconnect, with the cache more
warm state than fits in RAM.

## Layout

A rebar3 umbrella; each app is a separately publishable Hex package and the
repo is versioned as a whole.

| App | What it is |
|-----|------------|
| [`apps/barrel_inference`](apps/barrel_inference) | The runtime: dirty NIFs over llama.cpp, supervised model processes, token-exact tiered KV cache. |
| [`apps/barrel_inference_server`](apps/barrel_inference_server) | The API daemon: OpenAI-, Anthropic-, and Ollama-compatible HTTP, model registry, per-model queues, keep-alive, metrics. |
| [`apps/barrel_inference_cli`](apps/barrel_inference_cli) | The `barrel-inference` CLI: `serve` boots the daemon; `pull`/`run`/`ps`/`rm` drive a running one over HTTP. |

A distributed control plane (`barrel_inference_cluster`: routing, cache-aware
placement, node discovery) is a planned follow-up.

## Build

    rebar3 compile              # builds the NIF (vendored llama.cpp via cmake)
    rebar3 as prod release      # the barrel_inference_server daemon release
    rebar3 escriptize           # the barrel-inference CLI

Requires Erlang/OTP 28 and rebar3 3.25+, plus cmake and a C/C++ toolchain for
the NIF. See each app's README for the public API and configuration.

## Run

    barrel-inference serve                 # start the API server
    barrel-inference pull <model>          # fetch a model
    barrel-inference run <model> "hello"   # one-shot completion
    barrel-inference ps                    # list loaded models

Or with Docker:

    docker compose up

## License

MIT. Part of the [barrel-platform](https://github.com/barrel-platform) project.
