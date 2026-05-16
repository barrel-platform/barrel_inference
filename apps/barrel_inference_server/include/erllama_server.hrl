%%% erllama_server internal types and records.
%%%
%%% This header is internal: it is included by handler/pipeline modules
%%% but is not part of the public hex API surface.

-ifndef(ERLLAMA_SERVER_HRL).
-define(ERLLAMA_SERVER_HRL, true).

%% Endpoint API family. Determines which response shape the handler emits.
-type api() :: openai | anthropic.

%% Tool definition as it flows through the server. Both OpenAI and Anthropic
%% inputs are normalised to this shape by erllama_server_translate.
-type tool() :: #{
    name := binary(),
    description := binary(),
    %% JSON Schema
    schema := map()
}.

%% Tool-choice policy. Drives grammar generation.
-type tool_choice() :: auto | none | required | {named, binary()}.

%% Inference thinking mode.
-type thinking() :: disabled | enabled | max.

%% A single chat message, normalised. content is either a binary or a
%% list of content blocks (multi-modal, deferred to v0.2).
-type message() :: #{
    role := binary(),
    content := binary() | [map()]
}.

%% Internal request shape. Both OpenAI and Anthropic translators output
%% this; handlers consume it.
-record(erllama_request, {
    model_id :: binary(),
    %% chat / messages
    messages :: [message()],
    %% legacy /v1/completions
    prompt :: binary() | undefined,
    system :: binary() | undefined,
    tools :: [tool()] | undefined,
    tool_choice :: tool_choice(),
    %% GBNF source built from tools
    grammar :: binary() | undefined,
    max_tokens :: pos_integer(),
    temperature :: float(),
    top_p :: float(),
    top_k :: pos_integer(),
    min_p :: float(),
    seed :: integer() | undefined,
    stop :: [binary()],
    stream :: boolean(),
    thinking :: thinking(),
    api :: api(),
    request_id :: binary(),
    %% Ollama parity: keep_alive parsed into ms (`infinity` means
    %% never auto-unload, `0` means unload after this request).
    %% Defaults to `undefined` so handlers fall back to the
    %% server-wide default via erllama_server_config:keep_alive_default_ms/0.
    keep_alive_ms :: non_neg_integer() | infinity | undefined,
    %% true when the request is a load-only / unload-only short
    %% circuit (Ollama: empty prompt or empty messages).
    is_preload = false :: boolean(),
    %% Structured-output constraint. `text` = no grammar; any other
    %% value installs a GBNF that constrains the response.
    response_format = text :: text | json_object | {json_schema, map()},
    %% Anthropic prompt-caching markers captured from cache_control
    %% on system / tools / messages blocks. Each entry is the kind
    %% of block and the sha256 of its normalised content. Surfaced
    %% in `usage.cache_creation_input_tokens` /
    %% `usage.cache_read_input_tokens` on the way out.
    cache_hints = [] :: [
        #{
            kind := system | tool | message,
            hash := binary(),
            ttl := binary()
        }
    ],
    %% Optional metadata.user_id from Anthropic /v1/messages requests
    %% and the anthropic-beta header. Captured for observability; not
    %% currently passed to the engine. `undefined` when absent.
    user_id = undefined :: undefined | binary(),
    anthropic_beta = undefined :: undefined | binary(),
    %% Anthropic extended-thinking display preference. `visible`
    %% (default) emits thinking_delta SSE frames and a thinking
    %% content block on non-streaming responses; `omitted` suppresses
    %% both (the engine still produces thinking, the client just
    %% doesn't see it).
    thinking_display = visible :: visible | omitted,
    %% Anthropic thinking.budget_tokens hint. erllama 0.3.0 does not
    %% accept a thinking budget yet; we capture the value for
    %% forward compatibility and observability.
    thinking_budget = undefined :: undefined | pos_integer()
}).

%% Stats payload erllama emits in its erllama_done message. The exact
%% keys are an erllama prerequisite; the server is permissive on absent
%% keys.
-type stats() :: #{
    prompt_tokens => non_neg_integer(),
    completion_tokens => non_neg_integer(),
    prefill_ms => non_neg_integer(),
    generation_ms => non_neg_integer(),
    cache_hit_kind => exact | partial | cold,
    finish_reason => stop | length | cancelled | tool_call,
    cancelled => boolean(),
    _ => _
}.

-endif.
