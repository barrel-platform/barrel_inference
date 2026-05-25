%%% OpenAI /v1/chat/completions and /v1/completions handler.
%%%
%%% Pattern: cowboy_loop in both modes (streaming and non-streaming).
%%% Inference is async (barrel_inference:infer/4 sends `{barrel_inference_token, _, _}`),
%%% so the handler must sit in info/3.
%%%
%%% Lifecycle:
%%%
%%%   init/2
%%%     -> read body, json:decode, translate, resolve_model
%%%     (fast phase; failures land as JSON 4xx via cowboy_req:reply)
%%%
%%%   spawn pipeline worker
%%%   return {cowboy_loop, Req, State#st{phase = waiting_load}}
%%%
%%%   info/3 clauses
%%%     {pipeline, loaded}                  -> phase = waiting_template
%%%     {pipeline, templated, _}            -> phase = waiting_queue
%%%     {pipeline, queued}                  -> phase = waiting_admit
%%%     {pipeline, admitted, Ref, Slot}     -> phase = running
%%%                                            (stream=true: stream_reply 200)
%%%     {pipeline, error, Status, Reason}   -> JSON reply, stop
%%%     {barrel_inference_token, Ref, Bin}           -> emit chunk OR buffer (tool_buffer mode)
%%%     {barrel_inference_reasoning_token, Ref, Bin} -> emit reasoning chunk
%%%     {barrel_inference_done, Ref, Stats}          -> emit final + [DONE], stop
%%%     {barrel_inference_error, Ref, Reason}        -> emit error event, stop
%%%     {prefill_timeout|idle_timeout|total_timeout, Ref}
%%%                                         -> cancel + error
%%%
%%%   terminate/3
%%%     kill the pipeline worker, cancel any in-flight Ref, release
%%%     any held queue slot. Triggered on normal exit AND on TCP close.

-module(barrel_inference_server_h_chat).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% The catch-all `info(_Msg, ...)` clause is reachable in production
%% (stale messages from a previous request can land in the mailbox)
%% but dialyzer narrows the state record's phase too aggressively to
%% see it. Same applies to the catch-all in barrel_inference_server_h_messages.
-dialyzer({nowarn_function, info/3}).

-include("barrel_inference_server.hrl").

-record(st, {
    %% identity
    req_id :: binary(),
    model :: binary(),
    %% client-facing model name (alias kept)
    requested :: binary(),
    api :: openai | openai_legacy,
    stream :: boolean(),
    %% pipeline
    phase ::
        waiting_load
        | waiting_template
        | waiting_queue
        | waiting_admit
        | running,
    worker :: pid() | undefined,
    worker_mon :: reference() | undefined,
    %% Engine gen_statem monitor; armed on admit, cleared on
    %% barrel_inference_done / barrel_inference_error / terminate. See the matching
    %% comment in barrel_inference_server_h_messages.
    engine_mon :: reference() | undefined,
    %% admission outputs
    ref :: reference() | undefined,
    slot :: barrel_inference_server_queue:slot() | undefined,
    %% timers
    started_mono :: integer(),
    first_token_at :: integer() | undefined,
    prefill_tref :: reference() | undefined,
    idle_tref :: reference() | undefined,
    total_tref :: reference() | undefined,
    %% accounting
    out_tokens :: non_neg_integer(),
    %% buffers (non-streaming or tool buffering)
    buf_text :: iodata(),
    buf_reason :: iodata(),
    %% mode (text vs tool-call buffering)
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    %% OpenAI stream_options.include_usage: when true, the streaming
    %% finish emits a trailing usage-only chunk before [DONE].
    include_usage = false :: boolean(),
    %% true once stream_reply/3 has fired. Separate from `ref` because
    %% a loading keepalive can open the stream before admission.
    stream_started = false :: boolean(),
    %% Mirrors barrel_inference_server_h_messages: tracks whether we observed
    %% the engine's barrel_inference_done so cleanup can decide whether to
    %% end_session (cancelled mid-flight) or leave the pinned session
    %% alive (cross-turn reuse).
    received_done = false :: boolean(),
    session_id = undefined :: undefined | binary(),
    %% barrel_inference 0.5.0 wire-driven tool-call state. Mirrors the
    %% h_messages handler: when the model has `tool_call_markers' set,
    %% the engine emits `{tool_call_delta, _}' / `barrel_inference_tool_call_end'
    %% instead of routing tool JSON through the first-byte heuristic.
    %% Format spec cached at admission so the hot path doesn't re-read
    %% the manifest per request.
    tool_format = undefined :: undefined | barrel_inference_server_tool_format:spec(),
    %% barrel_inference 0.8 wire capture accumulates ALL tool calls the model
    %% emits in one generation; dispatched once on barrel_inference_done.
    captured_calls = [] ::
        [#{id := binary(), name := binary(), input := map(), full_bin := binary()}],
    %% Streaming tool-call text scanner for the native `tool_mode' path;
    %% undefined on the grammar path.
    tool_scan = undefined :: undefined | barrel_inference_server_tool_scan:state(),
    %% Built-in tools the server executes in-process, keyed by the
    %% model-facing name. Empty unless an executor is registered.
    server_tools = #{} :: #{binary() => barrel_inference_server_tool_executor:spec()},
    %% Agentic continue-loop state (engages only on a server_tools hit):
    %% run the executors server-side and re-invoke with the results
    %% appended, until the model answers without a server tool or the
    %% cap is hit. Mirrors barrel_inference_server_h_responses.
    tool_iter = 0 :: non_neg_integer(),
    max_tool_iter = 5 :: pos_integer(),
    loop_request = undefined :: undefined | #barrel_inference_request{},
    loop_messages = [] :: [map()],
    pending_exec = undefined ::
        undefined
        | #{
            batch_ref := reference(),
            calls := [barrel_inference_server_tool_batch:call()]
        },
    exec_mon = undefined :: undefined | reference(),
    exec_tref = undefined :: undefined | reference(),
    agg_stats = #{} :: map(),
    %% keepalive request_begin is refcounted; each loop round re-emits
    %% {pipeline, loaded}, so only the first round begins.
    keepalive_begun = false :: boolean(),
    %% Rendered prompt token ids for the current round, captured from
    %% {pipeline, templated, _}. With Stats.generated on barrel_inference_done
    %% they form the session's committed token-id list for the
    %% byte-exact continuation path.
    prompt_token_ids = [] :: [non_neg_integer()]
}).

%%====================================================================
%% init
%%====================================================================

init(Req0, Opts) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, Opts);
        _ -> reply_405(Req0)
    end.

handle_post(Req0, Opts) ->
    case barrel_inference_server_body:read(Req0) of
        {ok, Body, Req1} -> fast_phase(Body, Req1, Opts);
        {too_large, Req1} -> reply_json_error(413, request_too_large, Req1)
    end.

fast_phase(Body, Req0, Opts) ->
    Api = maps:get(api, Opts, openai),
    case decode(Body) of
        {ok, Map} -> translate(Map, Api, Req0);
        error -> reply_json_error(400, invalid_json, Req0)
    end.

translate(Map, Api, Req0) ->
    Translated =
        case Api of
            openai_legacy ->
                barrel_inference_server_translate:openai_completion_to_internal(Map);
            _ ->
                barrel_inference_server_translate:openai_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R} ->
            R1 = R#barrel_inference_request{
                session_id = barrel_inference_server_session:derive(Req0, R)
            },
            start_pipeline(R1, Api, Req0);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    end.

start_pipeline(R0, Api, Req0) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    {WorkerPid, Mon} = barrel_inference_server_pipeline:start_link(self(), R1),
    State0 = init_state(R1, Requested, Api, WorkerPid, Mon),
    State = arm_total_timer(State0),
    {cowboy_loop, Req0, State, hibernate}.

init_state(R, Requested, Api, Worker, Mon) ->
    Stream =
        case Api of
            openai_legacy -> R#barrel_inference_request.stream;
            _ -> R#barrel_inference_request.stream
        end,
    barrel_inference_server_metrics:inc_active_streams(R#barrel_inference_request.model_id),
    #st{
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = Requested,
        api = Api,
        stream = Stream,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        engine_mon = undefined,
        ref = undefined,
        slot = undefined,
        started_mono = mono_ms(),
        first_token_at = undefined,
        prefill_tref = undefined,
        idle_tref = undefined,
        total_tref = undefined,
        out_tokens = 0,
        buf_text = [],
        buf_reason = [],
        mode = text,
        grammar_set =
            grammar_active(R) andalso
                barrel_inference_server_tool_format:native_turn(R) =:= none,
        include_usage = R#barrel_inference_request.include_usage,
        session_id = R#barrel_inference_request.session_id,
        tool_format = resolve_tool_format(R#barrel_inference_request.model_id),
        tool_scan = init_tool_scan(R),
        server_tools = R#barrel_inference_request.server_tools,
        max_tool_iter = barrel_inference_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#barrel_inference_request.messages
    }.

init_tool_scan(R) ->
    case barrel_inference_server_tool_format:scanner_for(R) of
        {ok, Cfg} -> barrel_inference_server_tool_scan:new(Cfg);
        none -> undefined
    end.

resolve_tool_format(ModelId) ->
    case barrel_inference_server_tool_format:lookup(ModelId) of
        {ok, Spec} -> Spec;
        not_found -> undefined
    end.

%% Whether the pipeline is going to install a grammar for this
%% request. Determined by the presence of a non-empty tools array
%% and a non-`none` tool_choice. Read at handler-init time, before
%% the pipeline has actually built the GBNF.
grammar_active(#barrel_inference_request{tools = Tools, tool_choice = TC}) ->
    case {Tools, TC} of
        {undefined, _} -> false;
        {[], _} -> false;
        {_, none} -> false;
        _ -> true
    end.

%%====================================================================
%% info/3
%%====================================================================

%% --- pipeline progress ---
info({pipeline, loading, _ModelId}, Req0, S0 = #st{stream = true}) ->
    %% Long load: emit an SSE comment keepalive every tick. Opens
    %% the stream on the first tick so cowboy + downstream clients
    %% keep the connection alive.
    {Req1, S1} = ensure_stream(Req0, S0),
    ok = sse_comment(Req1, <<"loading">>),
    {ok, Req1, S1, hibernate};
info({pipeline, loading, _ModelId}, Req, S) ->
    %% Non-streaming request: nothing to write yet; cowboy
    %% idle_timeout (configured at the listener) is the safety net.
    {ok, Req, S, hibernate};
info({pipeline, loaded}, Req, S = #st{keepalive_begun = true}) ->
    %% Later loop round re-loading; keepalive already counted.
    {ok, Req, S#st{phase = waiting_template}, hibernate};
info({pipeline, loaded}, Req, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template, keepalive_begun = true}, hibernate};
info({pipeline, templated, Tokens}, Req, S) ->
    {ok, Req, S#st{phase = waiting_queue, prompt_token_ids = Tokens}, hibernate};
info({pipeline, queued}, Req, S) ->
    {ok, Req, S#st{phase = waiting_admit}, hibernate};
info({pipeline, admitted, Ref, Slot}, Req0, S0) ->
    %% learn_ref/3 may have arrived ahead of us via a token message;
    %% in that case phase/ref are already set and we just attach the
    %% queue slot. Otherwise this is the canonical admit point.
    S1 =
        case S0#st.ref of
            undefined -> arm_prefill_timer(S0#st{phase = running, ref = Ref});
            _ -> S0
        end,
    S2 = monitor_engine(S1#st{slot = Slot}),
    case S2#st.stream of
        true ->
            {Req1, S3} = ensure_stream(Req0, S2),
            {ok, Req1, S3, hibernate};
        false ->
            {ok, Req0, S2, hibernate}
    end;
info({pipeline, error, Status, Reason}, Req0, S = #st{stream_started = true}) ->
    %% Post-stream error: stream_reply has already gone out (loading
    %% keepalive opened it). Emit an SSE error frame instead of JSON,
    %% close the body, terminate the handler.
    record_metrics(S, Status),
    sse_event(Req0, <<"error">>, error_payload(Status, Reason)),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S};
info({pipeline, error, Status, Reason}, Req0, S) ->
    record_metrics(S, Status),
    Req1 = json_error(Status, Reason, Req0),
    {stop, Req1, S};
info(
    {'DOWN', Mon, process, _Pid, _Reason},
    Req0,
    S = #st{engine_mon = Mon}
) ->
    %% Engine gen_statem crashed mid-inference. Same handling as
    %% the messages handler: reroute to the pipeline-error path so
    %% the client sees 500 model_crashed.
    self() ! {pipeline, error, 500, model_crashed},
    {ok, Req0, S#st{engine_mon = undefined}, hibernate};
info(
    {'DOWN', Mon, process, Worker, _Reason},
    Req0,
    S = #st{worker = Worker, worker_mon = Mon}
) ->
    case S#st.phase of
        running ->
            %% Worker exits normally right after sending
            %% {pipeline, admitted}. The DOWN here is expected;
            %% inference continues independently.
            {ok, Req0, S#st{worker = undefined, worker_mon = undefined}, hibernate};
        _ ->
            Req1 = json_error(500, pipeline_crashed, Req0),
            {stop, Req1, S}
    end;
%% --- token messages ---
%% Token messages may arrive BEFORE {pipeline, admitted, ...} because
%% the pipeline worker calls barrel_inference:infer/4 (which immediately
%% starts decoding) and *then* sends `admitted` to the handler.
%% Because the handler is per-request, any token message in our
%% mailbox is necessarily ours; we don't need to match on Ref.
%% barrel_inference 0.5.0: per-chunk tool-call payload. The full body lands on
%% the matching `barrel_inference_tool_call_end' message; the deltas are
%% acknowledged so `learn_ref' records the slot ref and the idle
%% timer rearms.
info({barrel_inference_token, Ref, {tool_call_delta, _Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    {ok, Req, rearm_idle(first_token(S)), hibernate};
info({barrel_inference_tool_call_end, Ref, FullBin}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_tool_call_end(FullBin, Req, S);
info({barrel_inference_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
info({barrel_inference_reasoning_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Tok, Req, S);
info({barrel_inference_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    record_session_committed(S, Stats),
    S1 = accumulate_stats(S, Stats),
    case S1#st.pending_exec of
        undefined ->
            %% Captured tool calls (if any) may name server tools; if so,
            %% run them and continue the turn instead of finishing.
            dispatch_done(Req, flush_scan(Req, demonitor_engine(S1)));
        _ ->
            {ok, Req, demonitor_engine(S1), hibernate}
    end;
info({tool_exec_batch_result, Ref, Results}, Req, S = #st{pending_exec = #{batch_ref := Ref}}) ->
    continue_after_tools(Results, Req, S);
info({tool_exec_batch_result, _, _}, Req, S) ->
    {ok, Req, S, hibernate};
info({exec_timeout, Ref}, Req, S = #st{pending_exec = #{batch_ref := Ref}}) ->
    continue_after_tools({error, executor_timeout}, Req, S);
info({exec_timeout, _}, Req, S) ->
    {ok, Req, S, hibernate};
info({'DOWN', Mon, process, _Pid, normal}, Req, S = #st{exec_mon = Mon}) ->
    {ok, Req, S#st{exec_mon = undefined}, hibernate};
info({'DOWN', Mon, process, _Pid, Reason}, Req, S = #st{exec_mon = Mon, pending_exec = P}) when
    P =/= undefined
->
    continue_after_tools({error, {executor_crashed, Reason}}, Req, S);
info({barrel_inference_error, Ref, Reason}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_err(Req, demonitor_engine(S#st{received_done = true}), Reason);
%% --- timeouts ---
info({prefill_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, prefill_timeout);
info({idle_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, generation_idle_timeout);
info(total_request_timeout, Req, S = #st{phase = running, ref = Ref}) when is_reference(Ref) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, total_timeout);
info(total_request_timeout, Req0, S) ->
    %% Fired before admission. No SSE has started; reply with a JSON
    %% 504 and let terminate/3 clean up the worker.
    Req1 = json_error(504, total_timeout, Req0),
    record_metrics(S, 504),
    {stop, Req1, S};
%% barrel_inference 0.2.0 emits a token-id message alongside every token text
%% message. We do not consume it.
info({barrel_inference_token_id, _Ref, _Id}, Req, S) ->
    {ok, Req, S, hibernate};
%% --- catch-all (stale messages from a previous request, etc) ---
info(_Msg, Req, S) ->
    {ok, Req, S, hibernate}.

%%====================================================================
%% terminate
%%====================================================================

terminate(_Reason, _Req, S = #st{}) ->
    cleanup(S),
    ok;
terminate(_Reason, _Req, _) ->
    ok.

cleanup(S) ->
    cancel_timer(S#st.prefill_tref),
    cancel_timer(S#st.idle_tref),
    cancel_timer(S#st.total_tref),
    cancel_timer(S#st.exec_tref),
    case S#st.exec_mon of
        Mon when is_reference(Mon) -> erlang:demonitor(Mon, [flush]);
        _ -> ok
    end,
    _ = demonitor_engine(S),
    case is_pid(S#st.worker) of
        true -> barrel_inference_server_pipeline:abort(S#st.worker);
        false -> ok
    end,
    case S#st.ref of
        Ref when is_reference(Ref) -> barrel_inference:cancel(Ref);
        _ -> ok
    end,
    case S#st.slot of
        undefined -> ok;
        Slot -> barrel_inference_server_queue:release(S#st.model, Slot)
    end,
    case S#st.grammar_set of
        %% cleared by barrel_inference_model on finish_request
        true -> ok;
        false -> ok
    end,
    %% Cancelled mid-flight: free the pinned session so the next
    %% request can admit. Naturally-completed turns leave the session
    %% alive for cross-turn KV reuse. Mirrors barrel_inference_server_h_messages.
    maybe_end_session(S),
    %% Decrement the keepalive active count. If this was the last
    %% request, the model enters the keep-alive grace window.
    keepalive_release(S),
    barrel_inference_server_metrics:dec_active_streams(S#st.model).

maybe_end_session(#st{received_done = true}) ->
    ok;
maybe_end_session(#st{session_id = undefined}) ->
    ok;
maybe_end_session(#st{model = Model, session_id = SessionId}) ->
    try
        barrel_inference:end_session(Model, SessionId)
    catch
        _:_ -> ok
    end,
    barrel_inference_server_session_state:delete(Model, SessionId),
    ok.

record_session_committed(#st{session_id = undefined}, _) ->
    ok;
record_session_committed(
    #st{model = Model, session_id = SessionId, prompt_token_ids = Prompt}, Stats
) ->
    barrel_inference_server_session_state:record(Model, SessionId, Prompt, Stats).

%% Balance request_begin iff it ran. Keying off `keepalive_begun`
%% (not phase) is correct under the loop, where a re-load round resets
%% phase to waiting_load while the begin is still outstanding.
keepalive_release(#st{keepalive_begun = false}) ->
    ok;
keepalive_release(#st{model = Model}) ->
    barrel_inference_server_keepalive:request_end(
        Model, barrel_inference_server_config:keep_alive_default_ms()
    ).

%%====================================================================
%% Token handling
%%====================================================================

%% Native tool path: route tokens through the streaming scanner (content
%% vs tool calls); the engine emits no marker events here.
handle_token(Tok, Req, S0 = #st{tool_scan = Scan}) when Scan =/= undefined ->
    {Emits, Scan1} = barrel_inference_server_tool_scan:feed(Scan, Tok),
    apply_scan_emits(Emits, Req, first_token(S0#st{tool_scan = Scan1}));
handle_token(Tok, Req, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    %% First token of a grammar-mode request. If it starts with `{`,
    %% switch to tool_buffer mode so the JSON output is emitted as a
    %% single tool_calls chunk at the end rather than streamed as
    %% assistant text.
    case is_tool_first_byte(Tok) of
        true ->
            S1 = first_token(S),
            {ok, Req,
                rearm_idle(S1#st{
                    mode = tool_buffer,
                    buf_text = [Tok],
                    out_tokens = 1
                }), hibernate};
        false ->
            emit_text(Tok, Req, first_token(S))
    end;
handle_token(Tok, Req, S = #st{mode = tool_buffer}) ->
    %% Continue buffering JSON. No flush.
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text | Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate};
handle_token(Tok, Req, S = #st{mode = text, out_tokens = 0}) ->
    emit_text(Tok, Req, first_token(S));
handle_token(Tok, Req, S = #st{mode = text}) ->
    emit_text(Tok, Req, S).

emit_text(Tok, Req, S) ->
    {ok, Req, rearm_idle(stream_text(Tok, Req, S)), hibernate}.

%% Emit one text fragment (chunk or buffer) and return the updated state -
%% the reusable core of emit_text, also used for the scanner's {text,_}.
stream_text(<<>>, _Req, S) ->
    S;
stream_text(Tok, Req, S = #st{stream = true}) ->
    Iolist = barrel_inference_server_translate:internal_to_openai_chat_chunk(
        Tok, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body([<<"data: ">>, Iolist, <<"\n\n">>], nofin, Req),
    S#st{out_tokens = S#st.out_tokens + 1};
stream_text(Tok, _Req, S = #st{stream = false}) ->
    S#st{buf_text = [S#st.buf_text | Tok], out_tokens = S#st.out_tokens + 1}.

apply_scan_emits(Emits, Req, S0) ->
    S = lists:foldl(fun(E, Sx) -> apply_scan_emit(E, Req, Sx) end, S0, Emits),
    {ok, Req, rearm_idle(S), hibernate}.

apply_scan_emit({text, Bin}, Req, S) ->
    stream_text(Bin, Req, S);
apply_scan_emit({tool, #{name := Name, arguments := Args, raw := Raw}}, _Req, S) ->
    ToolId = make_tool_id_toolu(),
    maybe_persist_replay(S#st.tool_format, ToolId, S#st.model, Raw, Name, Args),
    Call = #{id => ToolId, name => Name, input => Args, full_bin => Raw},
    S#st{captured_calls = S#st.captured_calls ++ [Call]}.

flush_scan(_Req, S = #st{tool_scan = undefined}) ->
    S;
flush_scan(Req, S = #st{tool_scan = Scan}) ->
    {Emits, _} = barrel_inference_server_tool_scan:finish(Scan),
    lists:foldl(fun(E, Sx) -> apply_scan_emit(E, Req, Sx) end, S#st{tool_scan = undefined}, Emits).

handle_reasoning(Tok, Req, S = #st{stream = true}) ->
    Iolist = barrel_inference_server_translate:internal_to_openai_reasoning_chunk(
        Tok, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body([<<"data: ">>, Iolist, <<"\n\n">>], nofin, Req),
    {ok, Req, rearm_idle(S), hibernate};
handle_reasoning(Tok, Req, S = #st{stream = false}) ->
    {ok, Req, rearm_idle(S#st{buf_reason = [S#st.buf_reason | Tok]}), hibernate}.

%%====================================================================
%% Finish
%%====================================================================

finish_ok(Req0, S = #st{stream = true, mode = text}, Stats) ->
    Final = barrel_inference_server_translate:internal_to_openai_chat_final(
        Stats, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(
        [<<"data: ">>, Final, <<"\n\n">>, usage_chunk(S, Stats), <<"data: [DONE]\n\n">>],
        fin,
        Req0
    ),
    record_success(S, Stats),
    {stop, Req0, S};
finish_ok(Req0, S = #st{stream = true, mode = tool_buffer}, Stats) ->
    %% Emit one chat.completion.chunk with tool_calls populated, then
    %% [DONE]. v0.1 packs the entire JSON into a single delta entry.
    ToolStats = maps:put(finish_reason, tool_call, Stats),
    Final = openai_tool_call_chunk(S, iolist_to_binary(S#st.buf_text)),
    Stop = barrel_inference_server_translate:internal_to_openai_chat_final(
        ToolStats,
        S#st.req_id,
        S#st.requested
    ),
    cowboy_req:stream_body(
        [
            <<"data: ">>,
            Final,
            <<"\n\n">>,
            <<"data: ">>,
            Stop,
            <<"\n\n">>,
            usage_chunk(S, ToolStats),
            <<"data: [DONE]\n\n">>
        ],
        fin,
        Req0
    ),
    record_success(S, Stats),
    {stop, Req0, S};
finish_ok(Req0, S = #st{stream = false, api = Api}, Stats) ->
    Text = iolist_to_binary(S#st.buf_text),
    Body =
        case Api of
            openai_legacy ->
                barrel_inference_server_translate:internal_to_openai_completion_response(
                    Text, Stats, S#st.requested
                );
            _ ->
                barrel_inference_server_translate:internal_to_openai_chat_response(
                    Text, Stats, S#st.requested
                )
        end,
    Req1 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    record_success(S, Stats),
    {stop, Req1, S}.

finish_err(Req0, S = #st{stream = true}, Reason) ->
    Err = json:encode(#{
        <<"error">> => #{
            <<"message">> => to_bin(Reason),
            <<"type">> => <<"server_error">>,
            <<"code">> => to_bin(Reason)
        }
    }),
    cowboy_req:stream_body(
        [<<"data: ">>, Err, <<"\n\n">>, <<"data: [DONE]\n\n">>],
        fin,
        Req0
    ),
    record_error(S, Reason),
    {stop, Req0, S};
finish_err(Req0, S = #st{stream = false}, Reason) ->
    Status = http_status(Reason),
    Req1 = json_error(Status, Reason, Req0),
    record_error(S, Reason),
    {stop, Req1, S}.

%%====================================================================
%% Timers and metrics
%%====================================================================

first_token(S = #st{first_token_at = undefined}) ->
    Now = mono_ms(),
    PrefillSec = (Now - S#st.started_mono) / 1000.0,
    barrel_inference_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    arm_idle_timer(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

arm_prefill_timer(S) ->
    Ms = barrel_inference_server_config:prefill_ms(),
    case S#st.ref of
        undefined ->
            S;
        Ref ->
            S#st{
                prefill_tref = erlang:send_after(
                    Ms,
                    self(),
                    {prefill_timeout, Ref}
                )
            }
    end.

arm_idle_timer(S) ->
    rearm_idle(S).

rearm_idle(S) ->
    cancel_timer(S#st.idle_tref),
    Ms = barrel_inference_server_config:generation_idle_ms(),
    case S#st.ref of
        undefined ->
            S;
        Ref ->
            S#st{
                idle_tref = erlang:send_after(
                    Ms,
                    self(),
                    {idle_timeout, Ref}
                )
            }
    end.

%% Wall-clock timeout for the whole request. Armed at start_pipeline
%% time with a Ref-free message so it can fire before admission too.
arm_total_timer(S = #st{total_tref = undefined}) ->
    Ms = total_ms(),
    TRef = erlang:send_after(Ms, self(), total_request_timeout),
    S#st{total_tref = TRef}.

total_ms() ->
    case barrel_inference_server_config:total_ms() of
        N when is_integer(N), N > 0 -> N;
        _ -> 1800000
    end.

%% Capture the inference Ref on the first token/done/error message
%% if we have not seen `{pipeline, admitted, Ref, _}` yet. For
%% streaming requests also call `stream_reply` here so a body chunk
%% can be sent immediately. Idempotent when admit arrived first.
learn_ref(S = #st{ref = undefined, stream = true}, Req0, Ref) ->
    {Req1, S1} = ensure_stream(Req0, S),
    S2 = arm_prefill_timer(S1#st{phase = running, ref = Ref}),
    {S2, Req1};
learn_ref(S = #st{ref = undefined}, Req0, Ref) ->
    {arm_prefill_timer(S#st{phase = running, ref = Ref}), Req0};
learn_ref(S, Req, _Ref) ->
    {S, Req}.

%% Open the SSE stream exactly once. Subsequent calls are no-ops.
ensure_stream(Req, S = #st{stream_started = true}) ->
    {Req, S};
ensure_stream(Req0, S) ->
    Req1 = cowboy_req:stream_reply(200, sse_headers(), Req0),
    {Req1, S#st{stream_started = true}}.

sse_comment(Req, Text) ->
    cowboy_req:stream_body([<<": ">>, Text, <<"\n\n">>], nofin, Req),
    ok.

sse_event(Req, EventName, JsonMap) ->
    Frame = [
        <<"event: ">>,
        EventName,
        <<"\n">>,
        <<"data: ">>,
        json:encode(JsonMap),
        <<"\n\n">>
    ],
    cowboy_req:stream_body(Frame, nofin, Req),
    ok.

error_payload(Status, Reason) ->
    #{
        <<"error">> => #{
            <<"status">> => Status,
            <<"message">> => error_message(Reason)
        }
    }.

%% Mirror of barrel_inference_server_h_messages: monitor the engine on admit
%% so a NIF / gen_statem crash mid-inference surfaces cleanly.
monitor_engine(S = #st{engine_mon = Mon}) when is_reference(Mon) ->
    S;
monitor_engine(S = #st{model = Model}) ->
    case barrel_inference_registry:whereis_name(Model) of
        undefined -> S;
        Pid when is_pid(Pid) -> S#st{engine_mon = erlang:monitor(process, Pid)}
    end.

demonitor_engine(S = #st{engine_mon = Mon}) when is_reference(Mon) ->
    _ = erlang:demonitor(Mon, [flush]),
    S#st{engine_mon = undefined};
demonitor_engine(S) ->
    S.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

record_success(S, Stats) ->
    record_metrics(S, 200, Stats),
    barrel_inference_server_metrics:inc_prompt_tokens(
        S#st.model,
        maps:get(prompt_tokens, Stats, 0)
    ),
    barrel_inference_server_metrics:inc_completion_tokens(
        S#st.model,
        maps:get(completion_tokens, Stats, 0)
    ),
    case maps:get(generation_ms, Stats, 0) of
        0 ->
            ok;
        Ms ->
            Tokens = maps:get(completion_tokens, Stats, 0),
            case Tokens > 0 of
                true ->
                    Tps = (Tokens * 1000) / Ms,
                    barrel_inference_server_metrics:observe_generation_tps(S#st.model, Tps);
                false ->
                    ok
            end
    end.

record_error(S, _Reason) ->
    record_metrics(S, 500).

record_metrics(S, Status) -> record_metrics(S, Status, #{}).

record_metrics(S, Status, Stats) ->
    Now = mono_ms(),
    Duration = (Now - S#st.started_mono) / 1000.0,
    Endpoint =
        case S#st.api of
            openai_legacy -> <<"/v1/completions">>;
            _ -> <<"/v1/chat/completions">>
        end,
    barrel_inference_server_metrics:record_request(
        Endpoint, S#st.requested, integer_to_binary(Status), Duration
    ),
    %% Structured per-request log line. Mirrors the Anthropic handler:
    %% Stats on 200 carries cache_hit_kind + cache_delta so operators
    %% can measure cross-conversation prefix reuse from the daemon's
    %% logs. Error paths pass an empty Stats; cache fields collapse to
    %% defaults.
    logger:notice(
        maps:merge(
            #{
                event => openai_request,
                endpoint => Endpoint,
                model => S#st.requested,
                status => Status,
                duration_ms => round(Duration * 1000),
                request_id => S#st.req_id
            },
            cache_log_fields(Stats)
        )
    ).

cache_log_fields(Stats) ->
    Delta = maps:get(cache_delta, Stats, #{}),
    #{
        cache_hit_kind => maps:get(cache_hit_kind, Stats, undefined),
        cache_read_tokens => maps:get(read, Delta, 0),
        cache_created_tokens => maps:get(created, Delta, 0),
        prompt_tokens => maps:get(prompt_tokens, Stats, 0)
    }.

%%====================================================================
%% Reply helpers
%%====================================================================

reply_405(Req0) ->
    Req1 = cowboy_req:reply(405, #{}, <<>>, Req0),
    {ok, Req1, undefined}.

reply_json_error(Status, Reason, Req0) ->
    Req1 = json_error(Status, Reason, Req0),
    {ok, Req1, undefined}.

json_error(Status, Reason, Req0) ->
    Body = #{
        <<"error">> => #{
            <<"message">> => error_message(Reason),
            <<"type">> => error_type(Status),
            <<"code">> => error_code(Reason)
        }
    },
    cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ).

%% Render `error.message' as a sentence rather than an Erlang term.
%% OpenAI clients show the message verbatim, so a tuple printed with
%% `~p' (`{context_overflow,4500,4096}') leaks Erlang syntax.
error_message({context_overflow, Tokens, Ctx}) ->
    iolist_to_binary(
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum",
            [Tokens, Ctx]
        )
    );
error_message(Reason) ->
    to_bin(Reason).

%% Stable atom-style code for tooling; OpenAI uses these for retry /
%% UX decisions (e.g. `context_length_exceeded' is well-known).
error_code({context_overflow, _, _}) -> <<"context_length_exceeded">>;
error_code(Reason) -> to_bin(Reason).

error_type(400) -> <<"invalid_request_error">>;
error_type(404) -> <<"invalid_request_error">>;
error_type(429) -> <<"rate_limit_error">>;
error_type(500) -> <<"server_error">>;
error_type(503) -> <<"server_error">>;
error_type(504) -> <<"server_error">>;
error_type(_) -> <<"server_error">>.

http_status(prefill_timeout) -> 504;
http_status(generation_idle_timeout) -> 504;
http_status(total_timeout) -> 504;
http_status(_) -> 500.

sse_headers() ->
    #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"x-accel-buffering">> => <<"no">>
    }.

decode(Body) ->
    try
        case json:decode(Body) of
            Map when is_map(Map) -> {ok, Map};
            _ -> error
        end
    catch
        _:_ -> error
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

mono_ms() -> erlang:monotonic_time(millisecond).

%%====================================================================
%% Tool-call buffering
%%====================================================================

is_tool_first_byte(<<>>) -> false;
is_tool_first_byte(<<C, _/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n -> false;
is_tool_first_byte(<<${, _/binary>>) -> true;
is_tool_first_byte(_) -> false.

%% Trailing `stream_options.include_usage` chunk + its `data:`
%% framing, or empty iodata when the client didn't opt in. Slotted
%% into the finish stream just before `[DONE]`.
usage_chunk(#st{include_usage = false}, _Stats) ->
    [];
usage_chunk(S = #st{include_usage = true}, Stats) ->
    Chunk = barrel_inference_server_translate:internal_to_openai_usage_chunk(
        Stats, S#st.req_id, S#st.requested
    ),
    [<<"data: ">>, Chunk, <<"\n\n">>].

%% N wire-captured client calls in one chunk delta (index 0..N-1).
openai_tool_calls_chunk(S, Calls) ->
    {Entries, _} = lists:mapfoldl(
        fun(#{id := Id, name := Name, input := Input}, Ix) ->
            {
                #{
                    <<"index">> => Ix,
                    <<"id">> => Id,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => Name,
                        <<"arguments">> => iolist_to_binary(json:encode(Input))
                    }
                },
                Ix + 1
            }
        end,
        0,
        Calls
    ),
    Chunk = #{
        <<"id">> => S#st.req_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => erlang:system_time(second),
        <<"model">> => S#st.requested,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{
                    <<"role">> => <<"assistant">>,
                    <<"tool_calls">> => Entries
                },
                <<"finish_reason">> => null
            }
        ]
    },
    json:encode(Chunk).

openai_tool_call_chunk(S, JsonBin) ->
    {Name, ArgsJson, ToolId} = extract_tool_call(S, JsonBin),
    Created = erlang:system_time(second),
    Chunk = #{
        <<"id">> => S#st.req_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => S#st.requested,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{
                    <<"role">> => <<"assistant">>,
                    <<"tool_calls">> => [
                        #{
                            <<"index">> => 0,
                            <<"id">> => ToolId,
                            <<"type">> => <<"function">>,
                            <<"function">> => #{
                                <<"name">> => Name,
                                <<"arguments">> => ArgsJson
                            }
                        }
                    ]
                },
                <<"finish_reason">> => null
            }
        ]
    },
    json:encode(Chunk).

%% Legacy first-byte path: parse the buffered JSON into a single
%% tool_calls entry. (Wire-captured calls take the captured_calls path.)
extract_tool_call(_S, JsonBin) ->
    {Nm, Args} = parse_tool_call(JsonBin),
    {Nm, Args, make_tool_id()}.

%% barrel_inference 0.8 wire entry point: parse FullBin via the per-model
%% format module, mint a tool id, persist for next-turn exact replay,
%% and accumulate. The model may emit several spans; dispatch happens
%% once on barrel_inference_done so we know the full batch.
handle_tool_call_end(FullBin, Req, S = #st{tool_format = Spec, model = Model}) ->
    {Name, Input} = parse_full_bin(Spec, FullBin),
    ToolId = make_tool_id_toolu(),
    maybe_persist_replay(Spec, ToolId, Model, FullBin, Name, Input),
    Call = #{id => ToolId, name => Name, input => Input, full_bin => FullBin},
    {ok, Req, rearm_idle(S#st{captured_calls = S#st.captured_calls ++ [Call]}), hibernate}.

%% Parses FullBin to a `{Name, ArgsMap}' pair via the format module,
%% with a fall-back to the in-line `parse_tool_call/1' (which returns
%% a JSON string for arguments). When falling back, decode the JSON
%% so the captured `input' stays a map.
parse_full_bin(undefined, FullBin) ->
    parse_tool_call_to_map(FullBin);
parse_full_bin(Spec, FullBin) ->
    case barrel_inference_server_tool_format:parse(Spec, FullBin) of
        {ok, #{name := Name, arguments := Args}} -> {Name, Args};
        {error, _} -> parse_tool_call_to_map(FullBin)
    end.

parse_tool_call_to_map(JsonBin) when is_binary(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} when is_map(Args) ->
            {Name, Args};
        _ ->
            {<<"unknown">>, #{}}
    catch
        _:_ -> {<<"unknown">>, #{}}
    end;
parse_tool_call_to_map(_) ->
    {<<"unknown">>, #{}}.

maybe_persist_replay(undefined, _ToolId, _Model, _FullBin, _Name, _Input) ->
    ok;
maybe_persist_replay(_Spec, ToolId, Model, FullBin, Name, Input) ->
    barrel_inference_server_tool_replay:put(
        ToolId,
        Model,
        FullBin,
        #{name => Name, arguments => Input}
    ).

%%====================================================================
%% Agentic continue-loop (server-executed built-in tools)
%%====================================================================

%% Dispatch the model's captured tool calls once generation is done.
%% No wire calls -> the legacy first-byte path / plain finish. Else
%% honour parallel_tool_calls, split the batch: any server-targeted call
%% makes the turn CONTINUE (run all server calls concurrently, re-infer
%% once); a server-free batch FINISHES with N client tool_calls.
dispatch_done(Req, S = #st{captured_calls = []}) ->
    maybe_legacy_server_tool(Req, S#st{received_done = true});
dispatch_done(Req, S = #st{captured_calls = Calls0}) ->
    Calls = cap_parallel(S, Calls0),
    {ServerCalls, ClientCalls} = partition_calls(Calls, S#st.server_tools),
    case ServerCalls of
        [] -> finish_with_tool_calls(Req, S#st{received_done = true}, ClientCalls);
        _ -> begin_server_tools(ServerCalls, Req, S)
    end.

cap_parallel(#st{loop_request = #barrel_inference_request{parallel_tool_calls = false}}, Calls) ->
    lists:sublist(Calls, 1);
cap_parallel(_S, Calls) ->
    Calls.

partition_calls(Calls, ServerTools) ->
    lists:partition(fun(#{name := N}) -> maps:is_key(N, ServerTools) end, Calls).

%% Legacy first-byte path: the buffered JSON names a single tool. If it
%% is a server tool, run it and continue; else finish (text / one
%% tool_calls chunk via finish_ok's tool_buffer clause).
maybe_legacy_server_tool(Req, S = #st{mode = tool_buffer, server_tools = ST}) when
    map_size(ST) > 0
->
    {Name, Input} = parse_tool_call_to_map(iolist_to_binary(S#st.buf_text)),
    case maps:find(Name, ST) of
        {ok, _ExecSpec} ->
            Call = #{
                id => barrel_inference_server_translate:make_id(<<"call_">>),
                name => Name,
                input => Input,
                full_bin => iolist_to_binary(S#st.buf_text)
            },
            begin_server_tools([Call], Req, S);
        error ->
            finish_ok(Req, S#st{received_done = true}, S#st.agg_stats)
    end;
maybe_legacy_server_tool(Req, S) ->
    finish_ok(Req, S#st{received_done = true}, S#st.agg_stats).

%% Run all server-targeted calls concurrently off the handler process
%% via one coordinator; results arrive as one {tool_exec_batch_result,
%% BatchRef, _}.
begin_server_tools(ServerCalls, Req, S) ->
    Ctx = #{
        model => S#st.model,
        request_id => S#st.req_id,
        session_id => S#st.session_id
    },
    Batch = [
        #{
            call_id => Id,
            spec => maps:get(Name, S#st.server_tools),
            name => Name,
            args => Input,
            full_bin => FullBin
        }
     || #{id := Id, name := Name, input := Input, full_bin := FullBin} <- ServerCalls
    ],
    {_Pid, Mon, BatchRef} = barrel_inference_server_tool_batch:spawn_batch(Batch, Ctx),
    TRef = erlang:send_after(exec_timeout_ms(), self(), {exec_timeout, BatchRef}),
    Pending = #{batch_ref => BatchRef, calls => Batch},
    cancel_timer(S#st.idle_tref),
    {ok, Req,
        S#st{
            pending_exec = Pending,
            exec_mon = Mon,
            exec_tref = TRef,
            idle_tref = undefined,
            captured_calls = []
        },
        hibernate}.

%% All server-tool results are in (or the batch failed); fold every
%% (assistant call, tool result) pair into the conversation and
%% re-invoke ONCE on the warm session path.
continue_after_tools(Outcome, Req, S0) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_ok(
                Req,
                S#st{received_done = true, tool_iter = Iter, mode = text, buf_text = []},
                Stats
            );
        false ->
            NewMessages = S#st.loop_messages ++ tool_round_messages(Calls, Outcome),
            ContReq = (S#st.loop_request)#barrel_inference_request{messages = NewMessages},
            release_slot(S),
            {WorkerPid, Mon} = barrel_inference_server_pipeline:start_link(self(), ContReq),
            S2 = S#st{
                tool_iter = Iter,
                loop_messages = NewMessages,
                worker = WorkerPid,
                worker_mon = Mon,
                phase = waiting_load,
                ref = undefined,
                slot = undefined,
                mode = text,
                buf_text = [],
                out_tokens = 0,
                captured_calls = [],
                first_token_at = undefined
            },
            {ok, Req, S2, hibernate}
    end.

tool_round_messages(_Calls, Results) when is_list(Results) ->
    lists:flatmap(
        fun(#{call_id := CallId, full_bin := FullBin, result := Result}) ->
            round_pair(CallId, FullBin, result_json(Result))
        end,
        Results
    );
tool_round_messages(Calls, {error, _} = Err) ->
    EJson = result_json(Err),
    lists:flatmap(
        fun(#{call_id := CallId, full_bin := FullBin}) ->
            round_pair(CallId, FullBin, EJson)
        end,
        Calls
    ).

round_pair(CallId, FullBin, ResultJson) ->
    [
        #{role => <<"assistant">>, content => FullBin},
        #{
            role => <<"tool">>,
            content => <<"[tool_result id=", CallId/binary, "]: ", ResultJson/binary>>
        }
    ].

%% Surface every client tool call as a tool_calls entry and finish
%% (finish_reason = tool_calls). Streaming emits one chunk whose delta
%% carries N entries (index 0..N-1) then the final chunk; non-streaming
%% returns them in one response body.
finish_with_tool_calls(Req0, S = #st{stream = true}, Calls) ->
    ToolStats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    Final = openai_tool_calls_chunk(S, Calls),
    Stop = barrel_inference_server_translate:internal_to_openai_chat_final(
        ToolStats, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(
        [
            <<"data: ">>,
            Final,
            <<"\n\n">>,
            <<"data: ">>,
            Stop,
            <<"\n\n">>,
            usage_chunk(S, ToolStats),
            <<"data: [DONE]\n\n">>
        ],
        fin,
        Req0
    ),
    record_success(S, ToolStats),
    {stop, Req0, S};
finish_with_tool_calls(Req0, S = #st{stream = false}, Calls) ->
    Stats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    Body = barrel_inference_server_translate:internal_to_openai_chat_tool_calls_response(
        Calls, Stats, S#st.requested
    ),
    Req1 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    record_success(S, Stats),
    {stop, Req1, S}.

clear_pending(S) ->
    case S#st.exec_mon of
        Mon when is_reference(Mon) -> erlang:demonitor(Mon, [flush]);
        _ -> ok
    end,
    cancel_timer(S#st.exec_tref),
    S#st{pending_exec = undefined, exec_mon = undefined, exec_tref = undefined}.

release_slot(#st{slot = undefined}) ->
    ok;
release_slot(#st{model = Model, slot = Slot}) ->
    barrel_inference_server_queue:release(Model, Slot).

result_json({ok, Json}) when is_map(Json) ->
    iolist_to_binary(json:encode(Json));
result_json({ok, Bin}) when is_binary(Bin) ->
    Bin;
result_json({error, Reason}) ->
    iolist_to_binary(json:encode(#{<<"error">> => to_bin(Reason)})).

exec_timeout_ms() ->
    barrel_inference_server_config:generation_idle_ms().

accumulate_stats(S, Stats) ->
    S#st{agg_stats = merge_stats(S#st.agg_stats, Stats)}.

merge_stats(A, B) ->
    Sum = fun(K) -> maps:get(K, A, 0) + maps:get(K, B, 0) end,
    (maps:merge(A, B))#{
        prompt_tokens => Sum(prompt_tokens),
        completion_tokens => Sum(completion_tokens),
        prefill_ms => Sum(prefill_ms),
        generation_ms => Sum(generation_ms)
    }.

%% The Anthropic-style `toolu_' id is used in the replay-map row so
%% PR 6's render path uses one scheme across both endpoints.
make_tool_id_toolu() ->
    iolist_to_binary([
        <<"toolu_">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

%% The grammar emits `{"name":"...", "arguments":{...}}`. Parse and
%% re-encode the arguments as a JSON-encoded string (OpenAI schema).
parse_tool_call(JsonBin) ->
    case json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} ->
            {Name, json:encode(Args)};
        _ ->
            {<<"unknown">>, JsonBin}
    end.

make_tool_id() ->
    iolist_to_binary([
        <<"call_">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
