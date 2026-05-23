%%% Per-session committed-token tracking for the sticky-seq
%%% continuation path.
%%%
%%% erllama 0.8.0 reports the exact generated token ids in each
%%% request's final Stats (`generated'). Combined with the rendered
%%% prompt tokens of that turn, the committed token-id *list* the
%%% engine holds for the session is `PromptTokens ++ Generated'. We
%%% cache that list so the next turn can verify the freshly rendered
%%% prompt genuinely byte-extends it (a `lists:prefix/2' check) before
%%% routing the new suffix through `erllama:continue/3' with
%%% `expect_committed' set - the engine re-validates and returns
%%% `transcript_mismatch' rather than producing garbage if the slice
%%% is wrong.
%%%
%%% This module caches `{Model, SessionId} -> [token_id()]' in ETS.
%%% Set on `erllama_done' (only when the assembled length agrees with
%%% the engine's `committed_tokens' count), cleared on
%%% cancel-mid-flight (mirrors the handler's existing end_session
%%% policy). No DETS persistence: a server restart drops the list and
%%% the next turn falls back to a full `infer/4', which is correct
%%% (just slower until the cache rebuilds).

-module(erllama_server_session_state).
-behaviour(gen_server).

-export([start_link/0, get/2, put/3, record/4, delete/2]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(TABLE, ?MODULE).

%% Stored row: {{Model, SessionId}, CommittedTokenIds}.

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(binary(), binary()) -> {ok, [non_neg_integer()]} | not_found.
get(Model, SessionId) when is_binary(Model), is_binary(SessionId) ->
    case ets:lookup(?TABLE, {Model, SessionId}) of
        [{_, Tokens}] -> {ok, Tokens};
        [] -> not_found
    end.

-spec put(binary(), binary(), [non_neg_integer()]) -> ok.
put(Model, SessionId, Tokens) when
    is_binary(Model), is_binary(SessionId), is_list(Tokens)
->
    true = ets:insert(?TABLE, {{Model, SessionId}, Tokens}),
    ok.

%% Assemble and store the committed token-id list from a turn's
%% rendered prompt tokens and final Stats. Stores `Prompt ++ generated'
%% only when its length agrees with the engine's reported
%% `committed_tokens' count - otherwise the list would not match the
%% engine's stored context and the next continuation would be unsafe,
%% so we store nothing and the next turn falls back to a full infer.
%% No-ops when the engine reported no `generated' ids (older engine /
%% non-continuation paths) or the prompt tokens were not captured.
-spec record(binary(), binary(), [non_neg_integer()], map()) -> ok.
record(Model, SessionId, Prompt, Stats) when
    is_binary(Model), is_binary(SessionId), is_list(Prompt)
->
    case {maps:get(generated, Stats, undefined), maps:get(committed_tokens, Stats, undefined)} of
        {Gen, N} when is_list(Gen), Prompt =/= [], is_integer(N) ->
            Committed = Prompt ++ Gen,
            case length(Committed) =:= N of
                true -> put(Model, SessionId, Committed);
                false -> ok
            end;
        _ ->
            ok
    end.

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
