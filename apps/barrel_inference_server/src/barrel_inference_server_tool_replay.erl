%%% Exact-replay map for tool-call bytes. Maps a minted tool id
%%% (`toolu_...') to the FullBin the model sampled on the way out,
%%% the parsed `#{name, arguments}' JSON, and the model id that
%%% emitted it. PR 5's capture path writes here on every
%%% `{barrel_inference_tool_call_end, _, _}'; PR 6's render path reads here
%%% to splice the verbatim bytes back into the prompt on the next
%%% turn, falling back to the format module's canonicaliser on a
%%% miss.
%%%
%%% Hot path is ETS (named `?TABLE') so reads are O(1) without
%%% gen_server round-trips. The gen_server owns a DETS file behind
%%% the ETS table and syncs writes through; restarts replay the
%%% DETS contents back into ETS. A periodic gc walks ETS and evicts
%%% expired rows from both tables.

-module(barrel_inference_server_tool_replay).
-behaviour(gen_server).

-export([
    start_link/0,
    put/4,
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
-define(DETS, barrel_inference_server_tool_replay_dets).

%% Stored row: {ToolId, Model, FullBin, Json, ExpiresAt :: integer()}.
-record(row, {
    tool_id :: binary(),
    model :: binary(),
    full_bin :: binary(),
    json :: map(),
    expires_at :: integer()
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(binary(), binary(), binary(), map()) -> ok.
put(ToolId, Model, FullBin, Json) when
    is_binary(ToolId), is_binary(Model), is_binary(FullBin), is_map(Json)
->
    gen_server:cast(?MODULE, {put, ToolId, Model, FullBin, Json}).

-spec get(binary()) -> {ok, {binary(), binary(), map()}} | not_found.
get(ToolId) when is_binary(ToolId) ->
    Now = now_ms(),
    case ets:lookup(?TABLE, ToolId) of
        [#row{expires_at = ExpiresAt}] when ExpiresAt < Now ->
            not_found;
        [#row{model = M, full_bin = F, json = J}] ->
            {ok, {M, F, J}};
        [] ->
            not_found
    end.

-spec delete(binary()) -> ok.
delete(ToolId) when is_binary(ToolId) ->
    gen_server:cast(?MODULE, {delete, ToolId}).

%% Manual gc trigger; the gen_server also runs gc on a timer.
-spec gc() -> ok.
gc() ->
    gen_server:cast(?MODULE, gc).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    Dir = barrel_inference_server_config:tool_replay_dir(),
    ok = filelib:ensure_path(Dir),
    Path = filename:join(Dir, "replay.dets"),
    {ok, ?DETS} = dets:open_file(?DETS, [
        {file, Path},
        {keypos, #row.tool_id},
        {type, set},
        {auto_save, 60000}
    ]),
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        {keypos, #row.tool_id},
        {read_concurrency, true}
    ]),
    replay_dets_into_ets(),
    schedule_gc(),
    {ok, []}.

%% Replay DETS into ETS on boot. Skip expired rows so the ETS table
%% stays small even if the DETS file accumulated stale entries.
replay_dets_into_ets() ->
    Now = now_ms(),
    dets:foldl(
        fun(#row{expires_at = ExpiresAt} = Row, Acc) ->
            case ExpiresAt < Now of
                true ->
                    Acc;
                false ->
                    true = ets:insert(?TABLE, Row),
                    Acc + 1
            end
        end,
        0,
        ?DETS
    ).

handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast({put, ToolId, Model, FullBin, Json}, S) ->
    ExpiresAt = now_ms() + barrel_inference_server_config:tool_replay_ttl_ms(),
    Row = #row{
        tool_id = ToolId,
        model = Model,
        full_bin = FullBin,
        json = Json,
        expires_at = ExpiresAt
    },
    true = ets:insert(?TABLE, Row),
    ok = dets:insert(?DETS, Row),
    {noreply, S};
handle_cast({delete, ToolId}, S) ->
    true = ets:delete(?TABLE, ToolId),
    ok = dets:delete(?DETS, ToolId),
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
    case dets:info(?DETS) of
        undefined ->
            ok;
        _ ->
            ok = dets:sync(?DETS),
            ok = dets:close(?DETS)
    end,
    ok.

%%====================================================================
%% Internal
%%====================================================================

schedule_gc() ->
    Interval = barrel_inference_server_config:tool_replay_gc_interval_ms(),
    erlang:send_after(Interval, self(), gc_tick).

do_gc() ->
    Now = now_ms(),
    %% Match-spec uses the raw record tuple shape `{row, ToolId, ...}'
    %% rather than the `#row{...}' literal so dialyzer doesn't
    %% complain about `'$1' / '_'' violating the binary / map field
    %% type specs.
    Expired = ets:select(?TABLE, [
        {{row, '$1', '_', '_', '_', '$2'}, [{'<', '$2', Now}], ['$1']}
    ]),
    lists:foreach(
        fun(ToolId) ->
            true = ets:delete(?TABLE, ToolId),
            ok = dets:delete(?DETS, ToolId)
        end,
        Expired
    ),
    ok.

now_ms() ->
    erlang:system_time(millisecond).
