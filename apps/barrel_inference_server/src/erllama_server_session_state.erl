%%% Per-session committed-token tracking for the sticky-seq
%%% continuation path.
%%%
%%% erllama 0.6.0 ships `erllama:continue/3': prefill only a suffix
%%% on top of a pinned session's stored tokens (no prefix-equality
%%% check, caller asserts the slice is correct). To use it the
%%% server must know how many tokens of the *new* render correspond
%%% to the prior turn's stored state - that's the `committed_tokens'
%%% reported in each request's final Stats.
%%%
%%% This module caches `{Model, SessionId} -> committed_tokens' in
%%% ETS so the pipeline can slice the rendered prompt without
%%% re-tokenising prior history. Set on `erllama_done', cleared
%%% on cancel-mid-flight (mirrors the handler's existing
%%% end_session policy). No DETS persistence: a server restart
%%% drops the count and the next turn falls back to a full
%%% `infer/4', which is correct (just slower until the cache rebuilds).

-module(erllama_server_session_state).
-behaviour(gen_server).

-export([start_link/0, get/2, put/3, delete/2]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(TABLE, ?MODULE).

%% Stored row: {{Model, SessionId}, CommittedTokens}.

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(binary(), binary()) -> {ok, non_neg_integer()} | not_found.
get(Model, SessionId) when is_binary(Model), is_binary(SessionId) ->
    case ets:lookup(?TABLE, {Model, SessionId}) of
        [{_, N}] -> {ok, N};
        [] -> not_found
    end.

-spec put(binary(), binary(), non_neg_integer()) -> ok.
put(Model, SessionId, Count) when
    is_binary(Model), is_binary(SessionId), is_integer(Count), Count >= 0
->
    true = ets:insert(?TABLE, {{Model, SessionId}, Count}),
    ok.

-spec delete(binary(), binary()) -> ok.
delete(Model, SessionId) when is_binary(Model), is_binary(SessionId) ->
    true = ets:delete(?TABLE, {Model, SessionId}),
    ok.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, []}.

handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast(_, S) ->
    {noreply, S}.

handle_info(_, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    case ets:info(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end,
    ok.
