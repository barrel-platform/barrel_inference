%%% Per-model semaphore queue.
%%%
%%% A pure resource limiter: tracks `concurrency` slots and a FIFO of
%%% waiters. It never calls erllama and never sees erllama messages.
%%% The handler that owns the inference call is the slot holder; on
%%% terminate/3 it calls release/2 here so a client disconnect frees
%%% the slot just as cleanly as a normal completion.
%%%
%%% Every acquire returns a fresh `WaiterRef = make_ref()` that
%%% identifies that specific acquire attempt across the queue's life.
%%% Waiter timeouts use the ref so they cannot accidentally affect a
%%% later acquire by the same handler PID.

-module(erllama_server_queue).
-behaviour(gen_server).

-export([start_link/1, acquire/2, release/2, depth/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-type slot() :: reference().
-export_type([slot/0]).

-record(waiter, {
    ref :: reference(),
    pid :: pid(),
    mon :: reference(),
    from :: gen_server:from(),
    timer :: reference()
}).

-record(state, {
    model :: binary(),
    policy :: erllama_server_config:pool_policy() | undefined,
    concurrency :: pos_integer(),
    in_flight :: non_neg_integer(),
    depth_max :: pos_integer(),
    timeout :: pos_integer(),
    holders :: #{slot() => {pid(), reference()}},
    waiters :: queue:queue(#waiter{})
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(ModelId) when is_binary(ModelId) ->
    Name = {via, erllama_server_registry, {queue, ModelId}},
    gen_server:start_link(Name, ?MODULE, [ModelId], []).

-spec acquire(binary(), pos_integer()) -> {ok, slot()} | {error, atom()}.
acquire(ModelId, TimeoutMs) ->
    {ok, Pid} = erllama_server_queues_sup:ensure_queue(ModelId),
    %% TimeoutMs in the gen_server:call timeout slot to bound the wait;
    %% the queue itself uses internal timers to expire stragglers.
    try
        gen_server:call(Pid, {acquire, self(), TimeoutMs}, TimeoutMs + 1000)
    catch
        exit:{timeout, _} -> {error, queue_timeout}
    end.

-spec release(binary(), slot()) -> ok.
release(ModelId, Slot) when is_reference(Slot) ->
    case erllama_server_registry:whereis_name({queue, ModelId}) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {release, Slot})
    end.

-spec depth(binary()) -> non_neg_integer().
depth(ModelId) ->
    case erllama_server_registry:whereis_name({queue, ModelId}) of
        undefined -> 0;
        Pid -> gen_server:call(Pid, depth)
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([ModelId]) ->
    process_flag(trap_exit, true),
    Policy = erllama_server_config:pool_policy_for(ModelId),
    {Concurrency, Depth, Timeout} = policy_to_params(Policy),
    {ok, #state{
        model = ModelId,
        policy = Policy,
        concurrency = Concurrency,
        in_flight = 0,
        depth_max = Depth,
        timeout = Timeout,
        holders = #{},
        waiters = queue:new()
    }}.

handle_call({acquire, HandlerPid, _ReqTimeout}, _From, S = #state{policy = immediate_429}) ->
    case S#state.in_flight < S#state.concurrency of
        true ->
            {Slot, S1} = grant_slot(HandlerPid, S),
            {reply, {ok, Slot}, S1};
        false ->
            {reply, {error, pool_exhausted}, S}
    end;
handle_call({acquire, HandlerPid, ReqTimeout}, From, S) ->
    Depth = queue:len(S#state.waiters),
    if
        S#state.in_flight < S#state.concurrency ->
            {Slot, S1} = grant_slot(HandlerPid, S),
            {reply, {ok, Slot}, S1};
        Depth >= S#state.depth_max ->
            erllama_server_metrics:inc_queue_dropped(S#state.model, full),
            {reply, {error, pool_exhausted}, S};
        true ->
            WaiterRef = make_ref(),
            EffectiveTimeout = min(ReqTimeout, S#state.timeout),
            TRef = erlang:send_after(
                EffectiveTimeout,
                self(),
                {waiter_timeout, WaiterRef}
            ),
            Mon = monitor(process, HandlerPid),
            W = #waiter{
                ref = WaiterRef,
                pid = HandlerPid,
                mon = Mon,
                from = From,
                timer = TRef
            },
            S1 = S#state{waiters = queue:in(W, S#state.waiters)},
            erllama_server_metrics:set_queue_depth(
                S#state.model,
                queue:len(S1#state.waiters)
            ),
            {noreply, S1}
    end;
handle_call(depth, _From, S) ->
    {reply, queue:len(S#state.waiters), S};
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({release, Slot}, S = #state{holders = H}) ->
    case maps:take(Slot, H) of
        {{_HandlerPid, MonRef}, H1} ->
            demonitor(MonRef, [flush]),
            S1 = S#state{holders = H1, in_flight = S#state.in_flight - 1},
            {noreply, drain_waiter(S1)};
        error ->
            {noreply, S}
    end;
handle_cast(_, S) ->
    {noreply, S}.

handle_info({waiter_timeout, WaiterRef}, S) ->
    case take_waiter(WaiterRef, S#state.waiters) of
        {ok, W, Q1} ->
            demonitor(W#waiter.mon, [flush]),
            gen_server:reply(W#waiter.from, {error, queue_timeout}),
            erllama_server_metrics:inc_queue_dropped(S#state.model, timeout),
            erllama_server_metrics:set_queue_depth(S#state.model, queue:len(Q1)),
            {noreply, S#state{waiters = Q1}};
        notfound ->
            %% Timer fired after the waiter was admitted; safely ignore.
            {noreply, S}
    end;
handle_info({'DOWN', MonRef, process, Pid, _Reason}, S = #state{holders = H, waiters = Q}) ->
    %% A holder died without calling release/2. Drop its slot.
    case
        maps:fold(
            fun
                (Slot, {P, M}, Acc) when P =:= Pid, M =:= MonRef -> [Slot | Acc];
                (_, _, Acc) -> Acc
            end,
            [],
            H
        )
    of
        [Slot] ->
            H1 = maps:remove(Slot, H),
            S1 = S#state{holders = H1, in_flight = S#state.in_flight - 1},
            {noreply, drain_waiter(S1)};
        [] ->
            %% Maybe a queued waiter died; drop them.
            Q1 = queue:filter(
                fun(#waiter{pid = P, mon = M}) ->
                    not (P =:= Pid andalso M =:= MonRef)
                end,
                Q
            ),
            erllama_server_metrics:set_queue_depth(S#state.model, queue:len(Q1)),
            {noreply, S#state{waiters = Q1}}
    end;
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

policy_to_params(immediate_429) ->
    {1, 0, 30000};
policy_to_params({queue, #{concurrency := C, depth := D, timeout_ms := T}}) ->
    {C, D, T}.

grant_slot(HandlerPid, S = #state{holders = H, in_flight = N}) ->
    Mon = monitor(process, HandlerPid),
    Slot = make_ref(),
    {Slot, S#state{
        holders = H#{Slot => {HandlerPid, Mon}},
        in_flight = N + 1
    }}.

drain_waiter(S = #state{waiters = Q}) ->
    case queue:out(Q) of
        {empty, _} ->
            S;
        {{value, W}, Q1} ->
            _ = erlang:cancel_timer(W#waiter.timer),
            Slot = make_ref(),
            H1 = maps:put(Slot, {W#waiter.pid, W#waiter.mon}, S#state.holders),
            gen_server:reply(W#waiter.from, {ok, Slot}),
            erllama_server_metrics:set_queue_depth(S#state.model, queue:len(Q1)),
            S#state{waiters = Q1, holders = H1, in_flight = S#state.in_flight + 1}
    end.

take_waiter(Ref, Q) ->
    take_waiter(Ref, queue:to_list(Q), []).

take_waiter(_, [], _Acc) ->
    notfound;
take_waiter(Ref, [W = #waiter{ref = Ref} | Rest], Acc) ->
    {ok, W, queue:from_list(lists:reverse(Acc) ++ Rest)};
take_waiter(Ref, [W | Rest], Acc) ->
    take_waiter(Ref, Rest, [W | Acc]).
