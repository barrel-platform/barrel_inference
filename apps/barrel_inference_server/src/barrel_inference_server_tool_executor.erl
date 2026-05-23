%%% Server-side built-in tool executor registry. Mirrors
%%% `barrel_inference_server_tool_format': each OpenAI built-in tool type the
%%% server can execute in-process (web_search, code_interpreter, ...)
%%% gets one module implementing this behaviour, registered under its
%%% tool `type' binary in `barrel_inference_server_config:builtin_tool_executors/0'.
%%%
%%% The Responses translator consults `lookup_type/1' when it sees a
%%% built-in tool declaration: a registered type is offered to the
%%% model (its `declare/0' synthesises the model-facing `tool()') and
%%% recorded on `#barrel_inference_request.server_tools'; an unregistered type
%%% is dropped. The handler runs `execute/3' when the model calls a
%%% server tool and feeds the result back into generation (the
%%% agentic continue-loop).
%%%
%%% No executors ship by default - the registry is empty until an
%%% operator (or a test) adds one.

-module(barrel_inference_server_tool_executor).

-include("barrel_inference_server.hrl").

-export([lookup_type/1, declare/1, execute/3]).

%% Model-facing declaration: the tool name + JSON-Schema the grammar
%% constrains a call to. Static; no request state needed.
-callback declare() -> tool().

%% Run the built-in. Args is the parsed `arguments' object from the
%% model's tool call (already schema-constrained by the grammar). Ctx
%% carries request-scoped read-only context (see `execute/3'). The ok
%% result must be a JSON-encodable map; the handler folds it into
%% context as the tool result. An error is folded as an error result
%% so the model can recover rather than aborting the turn.
-callback execute(Args :: map(), Ctx :: map()) ->
    {ok, ResultJson :: map()} | {error, term()}.

%% A registry entry. `module' + `type' are required; any extra keys
%% are opaque backend config handed to the executor via `Ctx.config'.
-type spec() :: #{module := module(), type := binary(), _ => _}.

-export_type([spec/0]).

%% Resolve an OpenAI built-in tool `type' binary to its executor
%% spec. Returns `not_found' when no executor is registered for the
%% type - the translator then drops the tool.
-spec lookup_type(binary()) -> {ok, spec()} | not_found.
lookup_type(Type) when is_binary(Type) ->
    Executors = barrel_inference_server_config:builtin_tool_executors(),
    case maps:get(Type, Executors, undefined) of
        #{module := Mod} = Spec when is_atom(Mod) ->
            {ok, Spec};
        _ ->
            not_found
    end.

%% Dispatch the declaration to the executor module.
-spec declare(spec()) -> tool().
declare(#{module := Mod}) ->
    Mod:declare().

%% Dispatch execution to the executor module. `Ctx' is the
%% request-scoped read-only context: `#{model, request_id,
%% session_id, config}' where `config' is the spec minus
%% `module'/`type' (the entry's backend settings).
-spec execute(spec(), map(), map()) -> {ok, map()} | {error, term()}.
execute(#{module := Mod}, Args, Ctx) when is_map(Args), is_map(Ctx) ->
    Mod:execute(Args, Ctx).
