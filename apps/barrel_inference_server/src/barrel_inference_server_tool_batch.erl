%%% Concurrent server-side tool execution for one turn. When a model
%%% emits several tool calls in a single generation and one or more
%%% target a server-side executor (MCP bridge / built-in), the calls
%%% run in parallel rather than one-per-re-inference.
%%%
%%% The handler stays simple: it spawns ONE coordinator via
%%% `spawn_batch/2', keeps a single monitor + timeout timer, and waits
%%% for ONE `{tool_exec_batch_result, BatchRef, Results}' message. The
%%% coordinator fans out one linked worker per call, gathers the
%%% results in submit order, and replies. Workers are fully guarded so
%%% an executor crash becomes an `{error, _}' result, not a coordinator
%%% crash; if the handler kills the coordinator (timeout), the linked
%%% workers die with it.

-module(barrel_inference_server_tool_batch).

-export([spawn_batch/2]).

-type call() :: #{
    call_id := binary(),
    spec := barrel_inference_server_tool_executor:spec(),
    name := binary(),
    args := map(),
    full_bin := binary()
}.
-type result() :: #{
    call_id := binary(),
    name := binary(),
    full_bin := binary(),
    result := term()
}.

-export_type([call/0, result/0]).

%% Spawn the coordinator. Ctx is the per-handler executor context
%% (`#{model, request_id, session_id}'); each call's backend config is
%% taken from its own spec. Returns the coordinator pid, its monitor
%% reference, and the batch reference to match the reply on.
-spec spawn_batch([call()], map()) -> {pid(), reference(), reference()}.
spawn_batch(Calls, Ctx) ->
    Parent = self(),
    BatchRef = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Results = run_all(Calls, Ctx),
        Parent ! {tool_exec_batch_result, BatchRef, Results}
    end),
    {Pid, Mon, BatchRef}.

run_all(Calls, Ctx) ->
    Self = self(),
    %% Per-call wall-clock bound. The handler also bounds the whole
    %% batch (its exec_tref kills this coordinator, and the linked
    %% workers with it), so this is the inner safety net: a worker is
    %% fully guarded and always replies, so the only way `collect'
    %% blocks is an externally-killed worker.
    Deadline =
        erlang:monotonic_time(millisecond) + barrel_inference_server_config:generation_idle_ms(),
    Tagged = [{make_ref(), C} || C <- Calls],
    lists:foreach(
        fun({Tag, C}) ->
            spawn_link(fun() -> Self ! {Tag, exec_one(C, Ctx)} end)
        end,
        Tagged
    ),
    [collect(Tag, C, Deadline) || {Tag, C} <- Tagged].

collect(Tag, #{call_id := CallId, name := Name, full_bin := FullBin}, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    Result =
        receive
            {Tag, R} -> R
        after Remaining -> {error, executor_timeout}
        end,
    #{call_id => CallId, name => Name, full_bin => FullBin, result => Result}.

exec_one(#{spec := Spec, args := Args}, Ctx) ->
    Ctx1 = Ctx#{config => maps:without([module, type], Spec)},
    try
        barrel_inference_server_tool_executor:execute(Spec, Args, Ctx1)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.
