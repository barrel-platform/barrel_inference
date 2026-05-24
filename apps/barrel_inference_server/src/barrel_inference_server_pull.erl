%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_pull).
-moduledoc """
Per-pull coordinator. Owns the fetch and the manifest persistence for one
`pull`, so a completed download always registers a manifest even when the
HTTP handler that requested it has gone away (client disconnect, or cowboy
idle_timeout on a long download).

One gen_server per pull, spawned under `barrel_inference_server_pull_sup`
(simple_one_for_one, temporary). It calls `barrel_inference_server_fetch`
itself, so it is the fetch job's progress and done pid; on completion it
persists the manifest and only *then* reports success to its subscribers.
The HTTP handler is passed in as a subscriber at start and relays events to
the client; it never persists. Subscriber delivery is best-effort: the
coordinator is not linked to its subscribers, so it survives their death.

Events sent to each subscriber, tagged `{pull_event, CoordPid, Event}`:

- `{progress, Bytes, Total}`   byte progress during streaming
- `{phase, Phase}`             resolving / streaming (best-effort UX)
- `{status, Bin}`              `verifying sha256 digest` / `writing manifest`
- `{success, Manifest}`        persisted; the client may now list it
- `{error, Reason}`            fetch or persist failed
""".
-behaviour(gen_server).

-export([start_link/5]).
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    spec :: binary(),
    name :: binary(),
    tag :: binary(),
    overrides = #{} :: map(),
    subscribers = [] :: [pid()],
    job_ref :: undefined | binary()
}).

-type state() :: #state{}.

-spec start_link(binary(), binary(), binary(), map(), [pid()]) ->
    {ok, pid()} | {error, term()}.
start_link(Spec, Name, Tag, Overrides, Subscribers) ->
    gen_server:start_link(
        ?MODULE, {Spec, Name, Tag, Overrides, Subscribers}, []
    ).

init({Spec, Name, Tag, Overrides, Subscribers}) ->
    St = #state{
        spec = Spec,
        name = Name,
        tag = Tag,
        overrides = Overrides,
        subscribers = Subscribers
    },
    {ok, St, {continue, start_fetch}}.

%% Run the fetch in our own process so we are the job's progress + done
%% pid (and so a cache-hit's immediate done message lands here too).
handle_continue(start_fetch, #state{spec = Spec} = St) ->
    case barrel_inference_server_fetch:fetch_async(Spec, #{progress => self()}) of
        {ok, JobRef} ->
            {noreply, St#state{job_ref = JobRef}};
        {error, Reason} ->
            fail(St, Reason)
    end.

handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({barrel_inference_fetch_progress, Ref, Bytes, Total}, #state{job_ref = Ref} = St) ->
    notify(St, {progress, Bytes, Total}),
    {noreply, St};
handle_info({barrel_inference_fetch_phase, Ref, Phase}, #state{job_ref = Ref} = St) ->
    notify(St, {phase, Phase}),
    {noreply, St};
handle_info({barrel_inference_fetch_done, Ref, {ok, Path}}, #state{job_ref = Ref} = St) ->
    %% Persist before reporting success: the client must never see
    %% `success` before the manifest is durably on disk.
    notify(St, {status, <<"verifying sha256 digest">>}),
    case persist(St, Path) of
        {ok, Manifest} ->
            notify(St, {status, <<"writing manifest">>}),
            notify(St, {success, Manifest}),
            {stop, normal, St};
        {error, Reason} ->
            fail(St, Reason)
    end;
handle_info({barrel_inference_fetch_done, Ref, {error, Reason}}, #state{job_ref = Ref} = St) ->
    fail(St, Reason);
handle_info(_, St) ->
    {noreply, St}.

terminate(_Reason, _St) ->
    ok.

code_change(_Old, St, _Extra) ->
    {ok, St}.

%% =============================================================================
%% Internal
%% =============================================================================

%% Report a terminal error to subscribers and stop. The download blob (if
%% any) is already on disk; only the manifest failed to register.
-spec fail(state(), term()) -> {stop, normal, state()}.
fail(St, Reason) ->
    notify(St, {error, Reason}),
    {stop, normal, St}.

%% Guard persistence: the store can crash (e.g. an unwritable cache dir)
%% rather than return {error, _}; convert that into an error event so the
%% coordinator never dies silently and subscribers always hear an outcome.
persist(#state{spec = Spec, name = Name, tag = Tag, overrides = Overrides}, Path) ->
    try
        barrel_inference_server_models:persist_manifest_overrides(Spec, Name, Tag, Path, Overrides)
    of
        {ok, Manifest} -> {ok, Manifest};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {persist_crashed, Class, Reason}}
    end.

notify(#state{subscribers = Subs}, Event) ->
    Self = self(),
    _ = [Pid ! {pull_event, Self, Event} || Pid <- Subs, is_pid(Pid)],
    ok.
