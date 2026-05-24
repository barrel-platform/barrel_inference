# barrel-inference CLI

[![CI](https://github.com/barrel-platform/barrel_inference/actions/workflows/ci.yml/badge.svg)](https://github.com/barrel-platform/barrel_inference/actions/workflows/ci.yml)

`barrel-inference` is the command-line front end for Barrel Inference. It is a
single self-contained escript that does two jobs:

- **Launcher.** `serve` boots the release daemon
  ([`barrel_inference_server`](https://github.com/barrel-platform/barrel_inference/tree/main/apps/barrel_inference_server))
  on this machine.
- **Client.** Every other subcommand is a thin HTTP client (over hackney)
  against a running daemon. It loads no inference code and holds no Erlang
  dependency on the server app, so it ships and runs independently and can
  drive a daemon on another host.

The binary is built by `rebar3 escriptize` at
`_build/default/bin/barrel-inference` and is bundled into the release `bin/`
alongside the `barrel_inference_server` start script.

## Talking to a remote daemon

Client commands target `http://127.0.0.1:8080` by default. Point them at
another daemon with `BARREL_INFERENCE_HOST`:

    export BARREL_INFERENCE_HOST=http://gpu-box.internal:8080
    barrel-inference ps

`serve` is local-only: it execs the release start script found next to the
escript (or on `PATH`), so it must run from an installed release.

## Commands

| Command | What it does |
|---------|--------------|
| `serve [args...]` | Launch the release daemon. Foreground by default; extra args are forwarded to the `barrel_inference_server` start script (`start`, `stop`, `console`, ...). |
| `pull <name>` | Pull a model into the registry (streams progress). |
| `run <name> [prompt...]` | Stream a single chat completion. With no prompt, reads from stdin. |
| `ps` | List currently-loaded models. |
| `list` / `ls` | List registered models. |
| `show <name>` | Print one model manifest. |
| `rm <name>` / `delete <name>` | Remove a manifest. |
| `copy <src> <dst>` / `cp` | Alias a model under a new `name:tag`. |
| `search <query>` | Search HuggingFace / Ollama for models. |
| `embed <name> [text...]` | Compute an embedding vector. |
| `unload <name>` | Evict a model from memory now. |
| `version` / `-v` / `--version` | Print the server version. |
| `help` / `-h` / `--help` | Print usage. |

The `cluster` namespace is reserved: `barrel-inference cluster <subcmd>`
delegates to the distributed control plane CLI when that app is part of the
build, and reports a clear error otherwise.

## Examples

    # Boot the daemon in the foreground
    barrel-inference serve

    # Boot it in the background via the release start script
    barrel-inference serve start

    # Pull and run a model
    barrel-inference pull qwen2.5:0.5b
    barrel-inference run qwen2.5:0.5b "Write a haiku about supervision trees"

    # Pipe a prompt in
    echo "Summarise OTP in one line" | barrel-inference run qwen2.5:0.5b

    # Inspect a running daemon
    barrel-inference ps
    barrel-inference list
    barrel-inference show qwen2.5:0.5b

## Build

    rebar3 escriptize          # -> _build/default/bin/barrel-inference

See the [project README](https://github.com/barrel-platform/barrel_inference#readme)
for the umbrella build and the
[documentation site](https://barrel-platform.github.io/barrel_inference/) for
the full guides.

## License

MIT. Part of the [barrel-platform](https://github.com/barrel-platform) project.
