# Server-side tools

Most tool calls are *client-executed*: the model emits a tool call,
the server returns it, and your client runs the tool and sends the
result back on the next request. erllama_server can also run a
**built-in tool server-side**: when the model calls it, the server
executes the tool in-process, feeds the result back into the
conversation, and continues generating, until the model answers
without calling a server tool (or a per-request cap is reached). This
works on `/v1/responses`, `/v1/chat/completions`, and `/v1/messages`.

Nothing runs server-side unless you register an executor. Two ship:
`web_search` (multi-provider) and `web_fetch` (fetch one URL).

## Enable web_search

Register an executor in `config/sys.config` under
`builtin_tool_executors`, keyed by the tool `type`. Pick one provider:

```erlang
{erllama_server, [
  %% ... other settings ...
  {builtin_tool_executors, #{
    <<"web_search">> => #{
      module   => erllama_server_tool_executor_web_search,
      type     => <<"web_search">>,
      provider => tavily,            %% tavily | ollama | brave | searxng
      api_key  => <<"tvly-...">>
    }
  }},
  %% Cap on server-side tool rounds per request (default 5).
  {max_tool_iterations, 5}
]}
```

Provider config:

| provider  | keys                                  | backend                          |
|-----------|---------------------------------------|----------------------------------|
| `tavily`  | `api_key`                             | `api.tavily.com` (LLM-tuned)     |
| `ollama`  | `api_key`                             | `ollama.com/api/web_search`      |
| `brave`   | `api_key`                             | Brave Search API                 |
| `mojeek`  | `api_key`                             | Mojeek (UK/European, own index)  |
| `marginalia` | `api_key` (free public key: `public`) | Marginalia (Sweden, indie index) |
| `searxng` | `endpoint` (e.g. `http://host:8888`)  | your self-hosted SearXNG         |

Optional keys for any provider: `max_results` (default 5),
`timeout_ms` (default 10000), `endpoint` (override the default URL).

Restart the server after editing `sys.config`.

## Enable web_fetch

`web_fetch` retrieves a single model-supplied URL and returns its
readable text - the natural companion to `web_search` (search, then
fetch a result's full page). No provider/key:

```erlang
{builtin_tool_executors, #{
  <<"web_fetch">> => #{module => erllama_server_tool_executor_web_fetch,
                       type => <<"web_fetch">>}
}}
```

Optional config keys: `max_chars` (truncate the extracted text,
default 4000), `timeout_ms` (default 10000), `max_body` (cap the
downloaded bytes, default 5 MiB), `allow_private` (default `false`).

Because the URL is model-controlled, `web_fetch` is hardened against
SSRF: only `http`/`https`, TLS certificates are verified, the body and
extracted text are size-capped, and hosts that resolve to
loopback/private/link-local addresses (e.g. `127.0.0.1`,
`169.254.169.254`, `10.x`, `192.168.x`) are rejected with
`blocked_host` unless you set `allow_private => true`.

## Connect MCP servers

erllama_server can act as an **MCP client**: connect to one or more
[Model Context Protocol](https://modelcontextprotocol.io) servers and
offer *their* tools to the model through the same continue-loop. This
turns the whole MCP ecosystem (github, filesystem, databases, ...)
into server-side tools with no per-tool code.

List the servers in `mcp_servers` (each is a `barrel_mcp` connect spec
plus an `id`):

```erlang
{mcp_servers, [
  #{id => <<"github">>,
    transport => {http, <<"https://mcp.example.com/mcp">>},
    auth => {bearer, <<"...">>}},
  #{id => <<"fs">>,
    transport => {stdio, #{command => "mcp-server-filesystem",
                           args => ["/srv/data"]}}}
]}
```

On boot the server connects to each (a failed server is logged and
skipped), discovers their tools, and offers them on **every** request,
namespaced as `<id>__<tool>` (e.g. `github__create_issue`). When the
model calls one, the server routes it to the owning MCP server, folds
the result back into the conversation, and continues - the same loop
and `max_tool_iterations` cap as any server-side tool. `tool_choice =
none` still disables tools for a request. Empty `mcp_servers` (the
default) leaves the bridge off.

## Test it

With an executor registered, a model that decides to search will have
the search run server-side and the answer come back already grounded
in results. Force a search to verify the path end-to-end by sending
the tool plus a tool-choice that requires it:

```sh
# OpenAI Responses surface
curl -N -sX POST http://127.0.0.1:8080/v1/responses \
  -H 'content-type: application/json' \
  -d '{
    "model":"gpt-4o",
    "input":"What is the capital of France?",
    "tools":[{"type":"web_search"}],
    "tool_choice":"required",
    "max_output_tokens":128,
    "stream":true
  }'
```

```sh
# OpenAI chat surface
curl -sX POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model":"gpt-4o",
    "messages":[{"role":"user","content":"Latest news about Erlang/OTP?"}],
    "tools":[{"type":"web_search"}],
    "tool_choice":"required",
    "max_tokens":128
  }'
```

```sh
# Anthropic surface (versioned built-in type is normalised to web_search)
curl -sX POST http://127.0.0.1:8080/v1/messages \
  -H 'content-type: application/json' \
  -d '{
    "model":"claude-sonnet-4-5","max_tokens":256,
    "messages":[{"role":"user","content":"Who won the 2026 ... ?"}],
    "tools":[{"type":"web_search_20250305","name":"web_search"}],
    "tool_choice":{"type":"any"}
  }'
```

What to expect:

- The server runs the search in-process (no tool call is returned to
  you); the response text reflects the results.
- The search tool round is invisible on the wire (chat/messages) or
  surfaces as a `web_search_call` item (responses); the client just
  sees the final answer.
- A model that keeps calling the tool is bounded by
  `max_tool_iterations`; the turn then finishes with a
  length/`max_tokens` finish reason.

Provider-side checks: an unregistered/disabled `web_search` is simply
dropped from the request (no error, no search). A misconfigured
provider (missing `api_key`, unreachable `endpoint`) folds an error
result into the conversation so the model can recover rather than
failing the turn; the server logs the failure.

## Security notes

- **Indirect prompt injection.** Search and fetch results are
  attacker-influenced web content folded into the model's context. A
  page can contain text crafted to steer the model. Results enter as
  tool/user content (never as system instructions), but you can't
  fully prevent a model from being influenced - treat any
  tool-grounded output as untrusted, and be cautious chaining it into
  privileged actions.
- **SSRF.** `web_fetch` fetches model-supplied URLs server-side; its
  guard (above) blocks private/loopback hosts and verifies TLS. A
  self-hosted `searxng` `endpoint` you configure is trusted as-is.
- **Auth.** If the daemon listens on anything other than localhost,
  enable the `openai_api_keys` / `anthropic_api_keys` allowlist so the
  tool-running surface isn't open to the network.

## Write your own executor

A server-side tool is **one module plus one registry line**. The
module implements the `erllama_server_tool_executor` behaviour: two
callbacks, both surface-agnostic. You never touch the handlers, the
grammar, or the loop.

### The behaviour

```erlang
%% Static declaration: the model-facing tool. Called at request-parse
%% time, so it takes no arguments and must be pure.
-callback declare() -> tool().

%% Run the tool. Called once per tool round, in a separate process so
%% it can block on I/O without stalling the request.
-callback execute(Args :: map(), Ctx :: map()) ->
    {ok, ResultJson :: map()} | {error, term()}.
```

`tool()` is `#{name := binary(), description := binary(), schema :=
map()}` where `schema` is a JSON-Schema object for the arguments.

### declare/0

Returns the tool the model sees. The `name` becomes both the GBNF
grammar tool name and the key under which the executor is recorded, so
it must match the tool the model is expected to call. `schema`
constrains the arguments the model may produce.

```erlang
declare() ->
    #{name => <<"my_tool">>,
      description => <<"One line the model uses to decide when to call it.">>,
      schema => #{<<"type">> => <<"object">>,
                  <<"properties">> => #{<<"x">> => #{<<"type">> => <<"string">>}},
                  <<"required">> => [<<"x">>]}}.
```

### execute/2

`Args` is the parsed `arguments` object the model produced (already
constrained by `schema` via the grammar). `Ctx` is request-scoped,
read-only:

| key          | value                                                       |
|--------------|-------------------------------------------------------------|
| `model`      | resolved model id (binary)                                  |
| `request_id` | for log correlation (binary)                                |
| `session_id` | sticky-seq session (binary \| undefined)                    |
| `config`     | the registry entry minus `module`/`type` (your backend cfg) |

`config` is how an executor reads its own settings (api keys,
endpoints, limits): they come from the registry entry, never from
global app env. Return:

- `{ok, Map}` — `Map` must be JSON-encodable; it is folded into the
  conversation as the tool result and the model continues. Keep it
  compact and model-friendly (the model reads it as text).
- `{error, Reason}` — folded as an error result so the model can
  recover; it does **not** abort the turn. An executor crash or
  timeout is treated the same way.

```erlang
execute(#{<<"x">> := X}, #{config := Cfg}) ->
    Key = maps:get(api_key, Cfg, undefined),
    case do_work(X, Key) of
        {ok, Result} -> {ok, #{<<"result">> => Result}};
        {error, R}   -> {error, R}
    end.
```

### Things the framework handles for you

- **Concurrency**: `execute/2` runs in a monitored child process, so
  blocking on HTTP is fine. It is bounded by a timeout
  (`generation_idle_ms`); on timeout the round folds an error result.
- **The loop**: detecting the call, feeding the result back, the warm
  re-inference, the iteration cap (`max_tool_iterations`), and
  cancel-on-disconnect are all done for you.
- **Cross-surface**: the same executor runs on `/v1/responses`,
  `/v1/chat/completions`, and `/v1/messages`.

What you should NOT do: call back into the handler, hold long-lived
state across calls (each `execute/2` is independent), or assume the
model will call you exactly once (it may call across several rounds up
to the cap).

### Register it

In `config/sys.config`, keyed by the OpenAI/Anthropic tool `type` the
request carries (often the same string as the tool name):

```erlang
{builtin_tool_executors, #{
  <<"my_tool">> => #{module => my_tool_executor,
                     type => <<"my_tool">>,
                     %% any extra keys are passed through as Ctx.config
                     api_key => <<"...">>}
}}
```

Built-ins ship disabled (the default registry is empty); registering
an entry is what enables a tool. Anthropic sends versioned built-in
types (`web_search_20250305`); the server normalises the trailing
`_YYYYMMDD` to the canonical key before lookup, so register under the
canonical `type` (`web_search`).

`web_search` (`erllama_server_tool_executor_web_search`) is the
reference implementation if you want a worked example with a real
backend.
