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
    request_id :: binary()
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
