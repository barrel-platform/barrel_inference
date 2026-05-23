%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_fetch_srv).
-moduledoc """
Dedupe registry, progress fan-out, and async job tracker for the
fetch subsystem.

Three roles:

1. **Dedupe.** Concurrent calls for the same spec attach to the
   first call's worker rather than racing. Keyed by canonical spec
   hash.

2. **Progress.** Workers cast `{progress, Self, Bytes, Total}` and
   the srv fans them out as `{barrel_inference_fetch_progress, Ref, ...}`
   messages to subscribed pids. The latest report is kept in the
   job state so `status/1` can read it without polling the worker.

3. **Async lifecycle.** `download_async/2` returns immediately with
   a stable `JobRef` (the spec hash). When the worker reports
   completion the srv:

   - replies to all blocking `download/2` and `await/2` callers,
   - sends `{barrel_inference_fetch_done, JobRef, Result}` to every
     subscribed pid,
   - moves the entry to the `done` map for a TTL window so late
     `status/1`/`await/2` queries succeed.
""".
-behaviour(gen_server).

-export([
    start_link/0,
    download/2,
    download_async/2,
    status/1,
    await/2,
    subscribe/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([job_ref/0, status_result/0]).

-define(SERVER, ?MODULE).
-define(DONE_TTL_MS, 300_000).

-type job_ref() :: binary().

-type phase() :: starting | resolving | streaming.

-type status_result() ::
    {pending, #{
        phase := phase(),
        bytes := non_neg_integer(),
        total := non_neg_integer() | undefined
    }}
    | {done, {ok, file:filename_all()} | {error, term()}}
    | not_found.

-record(progress, {
    phase = starting :: phase(),
    bytes = 0 :: non_neg_integer(),
    total :: non_neg_integer() | undefined
}).

-record(job, {
    parsed :: barrel_inference_server_fetch_resolvers:parsed(),
    worker :: pid(),
    monitor :: reference(),
    %% gen_server From tuples awaiting the final reply (sync download/await).
    subscribers = [] :: [gen_server:from()],
    %% Pids that receive {barrel_inference_fetch_progress, JobRef, Bytes, Total}.
    progress_pids = [] :: [pid()],
    %% Pids that receive {barrel_inference_fetch_done, JobRef, Result} on completion.
    done_pids = [] :: [pid()],
    progress = #progress{} :: #progress{}
}).

-record(done_entry, {
    result :: {ok, file:filename_all()} | {error, term()},
    timer :: reference()
}).

-record(state, {
    jobs = #{} :: #{binary() => #job{}},
    done = #{} :: #{binary() => #done_entry{}}
}).

-type state() :: #state{}.

%% =============================================================================
%% Public API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Synchronous fetch. Blocks the caller until completion.
-spec download(barrel_inference_server_fetch_resolvers:parsed(), map()) ->
    {ok, file:filename_all()} | {error, term()}.
download(Parsed, Opts) when is_map(Opts) ->
    Timeout = maps:get(call_timeout, Opts, infinity),
    gen_server:call(?SERVER, {download_sync, Parsed, Opts}, Timeout).

%% Non-blocking fetch. The caller is auto-subscribed for the
%% completion message.
-spec download_async(barrel_inference_server_fetch_resolvers:parsed(), map()) -> {ok, job_ref()}.
download_async(Parsed, Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {download_async, Parsed, Opts, self()}).

-spec status(job_ref()) -> status_result().
status(JobRef) when is_binary(JobRef) ->
    gen_server:call(?SERVER, {status, JobRef}).

-spec await(job_ref(), timeout()) -> {ok, file:filename_all()} | {error, term()} | timeout.
await(JobRef, Timeout) when is_binary(JobRef) ->
    try
        gen_server:call(?SERVER, {await, JobRef}, Timeout)
    catch
        exit:{timeout, _} -> timeout
    end.

%% Add a pid to the done-subscriber list. If the job has already
%% finished (still in the TTL window), the message is sent
%% immediately. `not_found` if the job is unknown or expired.
-spec subscribe(job_ref(), pid()) -> ok | not_found.
subscribe(JobRef, Pid) when is_binary(JobRef), is_pid(Pid) ->
    gen_server:call(?SERVER, {subscribe, JobRef, Pid}).

%% =============================================================================
%% gen_server
%% =============================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({download_sync, Parsed, Opts}, From, St) ->
    Hash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
    do_ensure_job(Parsed, Opts, Hash, St, fun(Job) ->
        Job#job{subscribers = [From | Job#job.subscribers]}
    end);
handle_call({download_async, Parsed, Opts, Pid}, _From, St) ->
    Hash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
    case
        do_ensure_job(Parsed, Opts, Hash, St, fun(Job) ->
            Job#job{done_pids = lists:usort([Pid | Job#job.done_pids])}
        end)
    of
        {noreply, St1} -> {reply, {ok, Hash}, St1};
        {reply, Err, St1} -> {reply, Err, St1}
    end;
handle_call({status, Hash}, _From, St) ->
    {reply, status_of(Hash, St), St};
handle_call({await, Hash}, From, St) ->
    case maps:find(Hash, St#state.jobs) of
        {ok, Job} ->
            Job1 = Job#job{subscribers = [From | Job#job.subscribers]},
            {noreply, St#state{jobs = (St#state.jobs)#{Hash := Job1}}};
        error ->
            case lookup_done(Hash, St) of
                {ok, #done_entry{result = R}} -> {reply, R, St};
                not_found -> {reply, {error, unknown_job}, St}
            end
    end;
handle_call({subscribe, Hash, Pid}, _From, St) ->
    case maps:find(Hash, St#state.jobs) of
        {ok, Job} ->
            Job1 = Job#job{done_pids = lists:usort([Pid | Job#job.done_pids])},
            {reply, ok, St#state{jobs = (St#state.jobs)#{Hash := Job1}}};
        error ->
            case lookup_done(Hash, St) of
                {ok, #done_entry{result = R}} ->
                    Pid ! {barrel_inference_fetch_done, Hash, R},
                    {reply, ok, St};
                not_found ->
                    {reply, not_found, St}
            end
    end;
handle_call(_, _, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({progress, WorkerPid, Bytes, Total}, #state{jobs = Jobs} = St) ->
    case find_by_worker(WorkerPid, Jobs) of
        {ok, Hash, #job{progress_pids = Pids, progress = P0} = Job} ->
            _ = [Pid ! {barrel_inference_fetch_progress, Hash, Bytes, Total} || Pid <- Pids],
            P = P0#progress{phase = streaming, bytes = Bytes, total = Total},
            {noreply, St#state{jobs = Jobs#{Hash := Job#job{progress = P}}}};
        error ->
            {noreply, St}
    end;
handle_cast({phase, WorkerPid, Phase}, #state{jobs = Jobs} = St) ->
    case find_by_worker(WorkerPid, Jobs) of
        {ok, Hash, #job{progress = P0} = Job} ->
            P = P0#progress{phase = Phase},
            {noreply, St#state{jobs = Jobs#{Hash := Job#job{progress = P}}}};
        error ->
            {noreply, St}
    end;
handle_cast({done, WorkerPid, Result}, St) ->
    {noreply, finalize_job(WorkerPid, Result, St)};
handle_cast(_, St) ->
    {noreply, St}.

handle_info({'DOWN', _Mon, process, WorkerPid, Reason}, St) ->
    case find_by_worker(WorkerPid, St#state.jobs) of
        {ok, _Hash, _Job} ->
            Reply =
                case Reason of
                    normal -> {error, worker_exited_silently};
                    R -> {error, {worker_crashed, R}}
                end,
            {noreply, finalize_job(WorkerPid, Reply, St)};
        error ->
            {noreply, St}
    end;
handle_info({sweep_done, Hash}, #state{done = Done} = St) ->
    {noreply, St#state{done = maps:remove(Hash, Done)}};
handle_info(_, St) ->
    {noreply, St}.

terminate(_, _) -> ok.

%% =============================================================================
%% Internal
%% =============================================================================

do_ensure_job(Parsed, Opts, Hash, #state{jobs = Jobs} = St, Update) ->
    case maps:find(Hash, Jobs) of
        {ok, Job} ->
            Job1 = attach_progress(Update(Job), Opts),
            {noreply, St#state{jobs = Jobs#{Hash := Job1}}};
        error ->
            case barrel_inference_server_fetch_sup:start_worker(Parsed, Opts, self()) of
                {ok, Pid} ->
                    Mon = monitor(process, Pid),
                    Job0 = #job{
                        parsed = Parsed,
                        worker = Pid,
                        monitor = Mon,
                        progress_pids = progress_pid(Opts)
                    },
                    Job1 = Update(Job0),
                    {noreply, St#state{jobs = Jobs#{Hash => Job1}}};
                {error, Reason} ->
                    {reply, {error, {worker_start_failed, Reason}}, St}
            end
    end.

attach_progress(#job{progress_pids = Pids} = Job, Opts) ->
    Job#job{progress_pids = lists:usort(Pids ++ progress_pid(Opts))}.

progress_pid(Opts) ->
    case maps:find(progress, Opts) of
        {ok, Pid} when is_pid(Pid) -> [Pid];
        _ -> []
    end.

status_of(Hash, #state{jobs = Jobs, done = Done}) ->
    case maps:find(Hash, Jobs) of
        {ok, #job{progress = #progress{phase = Ph, bytes = B, total = T}}} ->
            {pending, #{phase => Ph, bytes => B, total => T}};
        error ->
            case maps:find(Hash, Done) of
                {ok, #done_entry{result = R}} -> {done, R};
                error -> not_found
            end
    end.

lookup_done(Hash, #state{done = Done}) ->
    case maps:find(Hash, Done) of
        {ok, _} = OK -> OK;
        error -> not_found
    end.

finalize_job(WorkerPid, Result, #state{jobs = Jobs, done = Done} = St) ->
    case find_by_worker(WorkerPid, Jobs) of
        {ok, Hash, #job{subscribers = Subs, monitor = Mon, done_pids = DPids}} ->
            demonitor(Mon, [flush]),
            _ = [gen_server:reply(From, Result) || From <- Subs],
            _ = [Pid ! {barrel_inference_fetch_done, Hash, Result} || Pid <- DPids],
            Timer = erlang:send_after(?DONE_TTL_MS, self(), {sweep_done, Hash}),
            Entry = #done_entry{result = Result, timer = Timer},
            St#state{
                jobs = maps:remove(Hash, Jobs),
                done = Done#{Hash => Entry}
            };
        error ->
            St
    end.

find_by_worker(Pid, Jobs) ->
    Found = maps:fold(
        fun
            (_, _, {found, _, _} = Acc) ->
                Acc;
            (Hash, #job{worker = WP} = Job, _Acc) when WP =:= Pid ->
                {found, Hash, Job};
            (_, _, Acc) ->
                Acc
        end,
        not_found,
        Jobs
    ),
    case Found of
        {found, H, J} -> {ok, H, J};
        not_found -> error
    end.
