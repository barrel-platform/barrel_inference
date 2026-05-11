%%% Per-model keep-alive timer.
%%%
%%% Mirrors Ollama's `keep_alive` semantics: a model stays warm in
%%% memory for N milliseconds after the last in-flight request
%%% finishes. While at least one request is in flight, the timer is
%%% never armed - this avoids unloading a model mid-stream during a
%%% long generation (the M3 finding in the review).
%%%
%%% API:
%%%
%%%   request_begin(ModelId)           - increment active count; cancel timer
%%%   request_end(ModelId, KeepAlive)  - decrement; if last and KA > 0, arm
%%%   unload_now(ModelId)              - force immediate unload
%%%
%%% `KeepAlive` accepts:
%%%
%%%   0        -> unload synchronously when active count reaches zero
%%%   infinity -> never auto-unload
%%%   N (ms)   -> schedule unload after N ms of inactivity
%%%
%%% On timer fire, `erllama:unload/1` is called and the per-model
%%% entry is removed.

-module(erllama_server_keepalive).
-behaviour(gen_server).

-export([start_link/0, request_begin/1, request_end/2, unload_now/1, status/0, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(entry, {
    active = 0 :: non_neg_integer(),
    timer :: undefined | reference(),
    %% Unix-time millisecond when the unload timer will fire. `infinity`
    %% if no timer is armed (active count > 0 OR keep_alive = infinity).
    expires_at_ms = infinity :: infinity | non_neg_integer()
}).

-record(state, {
    models = #{} :: #{binary() => #entry{}}
}).

-opaque state() :: #state{}.
-export_type([state/0]).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec request_begin(binary()) -> ok.
request_begin(ModelId) when is_binary(ModelId) ->
    gen_server:cast(?SERVER, {request_begin, ModelId}).

-spec request_end(binary(), non_neg_integer() | infinity) -> ok.
request_end(ModelId, KeepAlive) when is_binary(ModelId) ->
    gen_server:cast(?SERVER, {request_end, ModelId, KeepAlive}).

-spec unload_now(binary()) -> ok.
unload_now(ModelId) when is_binary(ModelId) ->
    gen_server:cast(?SERVER, {unload_now, ModelId}).

%% Returns a snapshot of the keepalive registry. Each entry carries
%% the current active request count and either `infinity` (no timer)
%% or the millisecond timestamp at which the unload timer will fire.
-spec status() ->
    [
        #{
            model := binary(),
            active := non_neg_integer(),
            expires_at_ms := infinity | non_neg_integer()
        }
    ].
status() ->
    gen_server:call(?SERVER, status).

-spec status(binary()) ->
    #{
        model := binary(),
        active := non_neg_integer(),
        expires_at_ms := infinity | non_neg_integer()
    }
    | not_tracked.
status(ModelId) when is_binary(ModelId) ->
    gen_server:call(?SERVER, {status, ModelId}).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call(status, _, S = #state{models = M}) ->
    {reply, snapshot_all(M), S};
handle_call({status, Id}, _, S = #state{models = M}) ->
    {reply, snapshot_one(Id, M), S};
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({request_begin, ModelId}, S = #state{models = M}) ->
    E0 = maps:get(ModelId, M, #entry{}),
    E1 = E0#entry{active = E0#entry.active + 1, timer = cancel_timer(E0#entry.timer)},
    {noreply, S#state{models = M#{ModelId => E1}}};
handle_cast({request_end, ModelId, KeepAlive}, S = #state{models = M}) ->
    case maps:find(ModelId, M) of
        {ok, E0} ->
            Active = max(0, E0#entry.active - 1),
            E1 = E0#entry{active = Active},
            case Active of
                0 -> {noreply, S#state{models = M#{ModelId => arm(ModelId, E1, KeepAlive)}}};
                _ -> {noreply, S#state{models = M#{ModelId => E1}}}
            end;
        error ->
            %% request_end without a matching request_begin; ignore.
            {noreply, S}
    end;
handle_cast({unload_now, ModelId}, S = #state{models = M}) ->
    case maps:find(ModelId, M) of
        {ok, E} -> _ = cancel_timer(E#entry.timer);
        error -> ok
    end,
    _ = unload(ModelId),
    {noreply, S#state{models = maps:remove(ModelId, M)}};
handle_cast(_, S) ->
    {noreply, S}.

handle_info({unload_timer, ModelId, Ref}, S = #state{models = M}) ->
    case maps:find(ModelId, M) of
        {ok, #entry{active = 0, timer = Ref}} ->
            _ = unload(ModelId),
            {noreply, S#state{models = maps:remove(ModelId, M)}};
        _ ->
            %% Stale timer (a new request bumped the count or a newer
            %% timer superseded this one). Ignore.
            {noreply, S}
    end;
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

arm(ModelId, E, 0) ->
    _ = cancel_timer(E#entry.timer),
    _ = unload(ModelId),
    E#entry{timer = undefined, expires_at_ms = infinity};
arm(_ModelId, E, infinity) ->
    E#entry{timer = cancel_timer(E#entry.timer), expires_at_ms = infinity};
arm(ModelId, E, Ms) when is_integer(Ms), Ms > 0 ->
    _ = cancel_timer(E#entry.timer),
    Ref = make_ref(),
    Timer = erlang:send_after(Ms, self(), {unload_timer, ModelId, Ref}),
    ExpiresAt = erlang:system_time(millisecond) + Ms,
    E#entry{timer = Timer, expires_at_ms = ExpiresAt};
arm(_ModelId, E, _) ->
    E#entry{timer = cancel_timer(E#entry.timer), expires_at_ms = infinity}.

cancel_timer(undefined) ->
    undefined;
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    undefined.

unload(ModelId) ->
    try erllama:unload(ModelId) of
        _ -> ok
    catch
        _:_ -> ok
    end.

snapshot_all(M) ->
    [snapshot_entry(Id, E) || {Id, E} <- maps:to_list(M)].

snapshot_one(Id, M) ->
    case maps:find(Id, M) of
        {ok, E} -> snapshot_entry(Id, E);
        error -> not_tracked
    end.

snapshot_entry(Id, #entry{active = N, expires_at_ms = X}) ->
    #{model => Id, active => N, expires_at_ms => X}.
