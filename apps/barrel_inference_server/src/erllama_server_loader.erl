%%% Per-model loader. Owns the (synchronous) erllama:load_model/2 call
%%% so that the config gen_server stays responsive. Multiple
%%% concurrent ensure_loaded/1 callers for the same model attach their
%%% From + Deadline to this loader; on completion (success or error)
%%% the loader replies to all of them, then exits normally.
%%%
%%% Time-bounded waiters whose deadline elapses while the load is
%%% still in flight are removed from the awaiter list and replied
%%% {error, load_timeout}. The loader keeps running because other
%%% awaiters may have longer deadlines, and so the next request finds
%%% the model already loaded.

-module(erllama_server_loader).
-behaviour(gen_server).

-export([start_link/1, await/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    model_id :: binary(),
    state :: loading | loaded | {failed, term()},
    %% From, Deadline
    awaiters :: [{gen_server:from(), integer()}]
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(ModelId) ->
    gen_server:start_link(?MODULE, [ModelId], []).

%% Cast our identity to the loader. The config server uses this to
%% park a caller's `From` until the loader finishes; the loader then
%% calls `gen_server:reply(From, ok | {error, _})`.
-spec await(pid(), gen_server:from(), integer()) -> ok.
await(Loader, From, Deadline) ->
    gen_server:cast(Loader, {await, From, Deadline}).

%%====================================================================
%% gen_server
%%====================================================================

init([ModelId]) ->
    self() ! start_load,
    {ok, #state{model_id = ModelId, state = loading, awaiters = []}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.

handle_cast({await, From, Deadline}, S = #state{state = loading, awaiters = A}) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            gen_server:reply(From, {error, load_timeout}),
            {noreply, S};
        false ->
            %% Schedule a self-message at the deadline to expire this
            %% specific awaiter if the load still has not finished.
            erlang:send_after(
                max(0, Deadline - Now),
                self(),
                {expire_awaiter, From}
            ),
            {noreply, S#state{awaiters = [{From, Deadline} | A]}}
    end;
handle_cast({await, From, _Deadline}, S = #state{state = loaded}) ->
    gen_server:reply(From, ok),
    {noreply, S};
handle_cast({await, From, _Deadline}, S = #state{state = {failed, Reason}}) ->
    gen_server:reply(From, {error, Reason}),
    {noreply, S};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(start_load, S = #state{model_id = ModelId}) ->
    Result =
        try erllama:load_model(ModelId, default_opts(ModelId)) of
            {ok, _ModelRef} -> ok;
            {error, Reason} -> {error, Reason}
        catch
            Class:Why:_Stack -> {error, {Class, Why}}
        end,
    NextState =
        case Result of
            ok -> loaded;
            {error, R} -> {failed, R}
        end,
    %% Reply to all current awaiters whose deadlines have not expired.
    Now = erlang:monotonic_time(millisecond),
    Reply =
        case Result of
            ok -> ok;
            {error, R2} -> {error, R2}
        end,
    lists:foreach(
        fun
            ({From, Deadline}) when Deadline >= Now ->
                gen_server:reply(From, Reply);
            (_) ->
                ok
        end,
        S#state.awaiters
    ),
    %% Stay alive on both success AND failure so late-arriving await
    %% casts (the cast race: start_load may fire before the awaiter
    %% registers) get the cached state. The config server's `'DOWN'`
    %% handler removes the loader entry; an explicit retry would need
    %% a separate API in a future version.
    {noreply, S#state{state = NextState, awaiters = []}};
handle_info({expire_awaiter, From}, S = #state{state = loading, awaiters = A}) ->
    case lists:keytake(From, 1, A) of
        {value, {From, _}, A1} ->
            gen_server:reply(From, {error, load_timeout}),
            {noreply, S#state{awaiters = A1}};
        false ->
            {noreply, S}
    end;
handle_info({expire_awaiter, _}, S) ->
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

default_opts(_ModelId) ->
    %% Hook for per-model load options; for v0.1 we hand off the empty
    %% map and let erllama use its defaults.
    #{}.
