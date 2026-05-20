%%% Server-side store for the Responses API `previous_response_id'
%%% continuation. Maps a minted `resp_...' id to the full conversation
%%% that produced it (prior input messages + this turn's assistant
%%% reply, in the internal `#{role, content}' shape) plus the model
%%% that served it.
%%%
%%% A follow-up `/v1/responses' request carrying `previous_response_id'
%%% omits the earlier turns; the handler looks the id up here and
%%% prepends the stored messages so the chat template renders the full
%%% history. Storing the whole conversation (not just the latest
%%% output) keeps chains correct: each turn restores the previous
%%% turn's messages and appends its own reply, so the next lookup
%%% carries everything.
%%%
%%% RAM only: a server restart drops the map and the client falls back
%%% to replaying the conversation in `input', which OpenAI clients do
%%% anyway. Reads are O(1) off a public ETS table; a TTL stamped at
%%% insert plus a periodic gc bound the table size.

-module(erllama_server_response_store).
-behaviour(gen_server).

-export([
    start_link/0,
    put/3,
    get/1,
    delete/1,
    gc/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(TABLE, ?MODULE).

%% Stored row: {ResponseId, Model, Messages, ExpiresAt :: integer()}.
-record(row, {
    response_id :: binary(),
    model :: binary(),
    messages :: [map()],
    expires_at :: integer()
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(binary(), binary(), [map()]) -> ok.
put(ResponseId, Model, Messages) when
    is_binary(ResponseId), is_binary(Model), is_list(Messages)
->
    gen_server:cast(?MODULE, {put, ResponseId, Model, Messages}).

-spec get(binary()) -> {ok, {binary(), [map()]}} | not_found.
get(ResponseId) when is_binary(ResponseId) ->
    Now = now_ms(),
    case ets:lookup(?TABLE, ResponseId) of
        [#row{expires_at = ExpiresAt}] when ExpiresAt < Now ->
            not_found;
        [#row{model = M, messages = Msgs}] ->
            {ok, {M, Msgs}};
        [] ->
            not_found
    end.

-spec delete(binary()) -> ok.
delete(ResponseId) when is_binary(ResponseId) ->
    gen_server:cast(?MODULE, {delete, ResponseId}).

%% Manual gc trigger; the gen_server also runs gc on a timer.
-spec gc() -> ok.
gc() ->
    gen_server:cast(?MODULE, gc).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {keypos, #row.response_id},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    schedule_gc(),
    {ok, []}.

handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast({put, ResponseId, Model, Messages}, S) ->
    ExpiresAt = now_ms() + erllama_server_config:responses_store_ttl_ms(),
    Row = #row{
        response_id = ResponseId,
        model = Model,
        messages = Messages,
        expires_at = ExpiresAt
    },
    true = ets:insert(?TABLE, Row),
    {noreply, S};
handle_cast({delete, ResponseId}, S) ->
    true = ets:delete(?TABLE, ResponseId),
    {noreply, S};
handle_cast(gc, S) ->
    do_gc(),
    {noreply, S};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(gc_tick, S) ->
    do_gc(),
    schedule_gc(),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    case ets:info(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end,
    ok.

%%====================================================================
%% Internal
%%====================================================================

schedule_gc() ->
    Interval = erllama_server_config:responses_store_gc_interval_ms(),
    erlang:send_after(Interval, self(), gc_tick).

do_gc() ->
    Now = now_ms(),
    %% Match-spec uses the raw record tuple shape rather than the
    %% `#row{...}' literal so dialyzer doesn't complain about
    %% `'$1' / '_'' violating the field type specs.
    Expired = ets:select(?TABLE, [
        {{row, '$1', '_', '_', '$2'}, [{'<', '$2', Now}], ['$1']}
    ]),
    lists:foreach(fun(Id) -> true = ets:delete(?TABLE, Id) end, Expired),
    ok.

now_ms() ->
    erlang:system_time(millisecond).
