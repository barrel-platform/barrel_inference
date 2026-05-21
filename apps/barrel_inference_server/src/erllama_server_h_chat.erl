%%% OpenAI /v1/chat/completions and /v1/completions handler.
%%%
%%% Pattern: cowboy_loop in both modes (streaming and non-streaming).
%%% Inference is async (erllama:infer/4 sends `{erllama_token, _, _}`),
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
%%%     {erllama_token, Ref, Bin}           -> emit chunk OR buffer (tool_buffer mode)
%%%     {erllama_reasoning_token, Ref, Bin} -> emit reasoning chunk
%%%     {erllama_done, Ref, Stats}          -> emit final + [DONE], stop
%%%     {erllama_error, Ref, Reason}        -> emit error event, stop
%%%     {prefill_timeout|idle_timeout|total_timeout, Ref}
%%%                                         -> cancel + error
%%%
%%%   terminate/3
%%%     kill the pipeline worker, cancel any in-flight Ref, release
%%%     any held queue slot. Triggered on normal exit AND on TCP close.

-module(erllama_server_h_chat).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% The catch-all `info(_Msg, ...)` clause is reachable in production
%% (stale messages from a previous request can land in the mailbox)
%% but dialyzer narrows the state record's phase too aggressively to
%% see it. Same applies to the catch-all in erllama_server_h_messages.
-dialyzer({nowarn_function, info/3}).

-include("erllama_server.hrl").

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
    %% erllama_done / erllama_error / terminate. See the matching
    %% comment in erllama_server_h_messages.
    engine_mon :: reference() | undefined,
    %% admission outputs
    ref :: reference() | undefined,
    slot :: erllama_server_queue:slot() | undefined,
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
    %% Mirrors erllama_server_h_messages: tracks whether we observed
    %% the engine's erllama_done so cleanup can decide whether to
    %% end_session (cancelled mid-flight) or leave the pinned session
    %% alive (cross-turn reuse).
    received_done = false :: boolean(),
    session_id = undefined :: undefined | binary(),
    %% erllama 0.5.0 wire-driven tool-call state. Mirrors the
    %% h_messages handler: when the model has `tool_call_markers' set,
    %% the engine emits `{tool_call_delta, _}' / `erllama_tool_call_end'
    %% instead of routing tool JSON through the first-byte heuristic.
    %% Format spec cached at admission so the hot path doesn't re-read
    %% the manifest per request.
    tool_format = undefined :: undefined | erllama_server_tool_format:spec(),
    captured_tool_use = undefined ::
        undefined | #{id := binary(), name := binary(), input := map()},
    %% Built-in tools the server executes in-process, keyed by the
    %% model-facing name. Empty unless an executor is registered.
    server_tools = #{} :: #{binary() => erllama_server_tool_executor:spec()},
    %% Agentic continue-loop state (engages only on a server_tools hit):
    %% run the executor server-side and re-invoke with the result
    %% appended, until the model answers without a server tool or the
    %% cap is hit. Mirrors erllama_server_h_responses.
    tool_iter = 0 :: non_neg_integer(),
    max_tool_iter = 5 :: pos_integer(),
    loop_request = undefined :: undefined | #erllama_request{},
    loop_messages = [] :: [map()],
    pending_exec = undefined ::
        undefined
        | #{
            spec := erllama_server_tool_executor:spec(),
            name := binary(),
            args := map(),
            call_id := binary(),
            full_bin := binary()
        },
    exec_mon = undefined :: undefined | reference(),
    exec_tref = undefined :: undefined | reference(),
    agg_stats = #{} :: map(),
    %% keepalive request_begin is refcounted; each loop round re-emits
    %% {pipeline, loaded}, so only the first round begins.
    keepalive_begun = false :: boolean()
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
    case erllama_server_body:read(Req0) of
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
                erllama_server_translate:openai_completion_to_internal(Map);
            _ ->
                erllama_server_translate:openai_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R} ->
            R1 = R#erllama_request{
                session_id = erllama_server_session:derive(Req0, R)
            },
            start_pipeline(R1, Api, Req0);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    end.

start_pipeline(R0, Api, Req0) ->
    Requested = R0#erllama_request.model_id,
    Real = erllama_server_config:resolve_model(Requested),
    R1 = R0#erllama_request{model_id = Real},
    {WorkerPid, Mon} = erllama_server_pipeline:start_link(self(), R1),
    State0 = init_state(R1, Requested, Api, WorkerPid, Mon),
    State = arm_total_timer(State0),
    {cowboy_loop, Req0, State, hibernate}.

init_state(R, Requested, Api, Worker, Mon) ->
    Stream =
        case Api of
            openai_legacy -> R#erllama_request.stream;
            _ -> R#erllama_request.stream
        end,
    erllama_server_metrics:inc_active_streams(R#erllama_request.model_id),
    #st{
        req_id = R#erllama_request.request_id,
        model = R#erllama_request.model_id,
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
        grammar_set = grammar_active(R),
        include_usage = R#erllama_request.include_usage,
        session_id = R#erllama_request.session_id,
        tool_format = resolve_tool_format(R#erllama_request.model_id),
        server_tools = R#erllama_request.server_tools,
        max_tool_iter = erllama_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#erllama_request.messages
    }.

resolve_tool_format(ModelId) ->
    case erllama_server_tool_format:lookup(ModelId) of
        {ok, Spec} -> Spec;
        not_found -> undefined
    end.

%% Whether the pipeline is going to install a grammar for this
%% request. Determined by the presence of a non-empty tools array
%% and a non-`none` tool_choice. Read at handler-init time, before
%% the pipeline has actually built the GBNF.
grammar_active(#erllama_request{tools = Tools, tool_choice = TC}) ->
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
    ok = erllama_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template, keepalive_begun = true}, hibernate};
info({pipeline, templated, _Tokens}, Req, S) ->
    {ok, Req, S#st{phase = waiting_queue}, hibernate};
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
%% the pipeline worker calls erllama:infer/4 (which immediately
%% starts decoding) and *then* sends `admitted` to the handler.
%% Because the handler is per-request, any token message in our
%% mailbox is necessarily ours; we don't need to match on Ref.
%% erllama 0.5.0: per-chunk tool-call payload. The full body lands on
%% the matching `erllama_tool_call_end' message; the deltas are
%% acknowledged so `learn_ref' records the slot ref and the idle
%% timer rearms.
info({erllama_token, Ref, {tool_call_delta, _Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    {ok, Req, rearm_idle(first_token(S)), hibernate};
info({erllama_tool_call_end, Ref, FullBin}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_tool_call_end(FullBin, Req, S);
info({erllama_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
info({erllama_reasoning_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Tok, Req, S);
info({erllama_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    record_session_committed(S, Stats),
    S1 = accumulate_stats(S, Stats),
    case S1#st.pending_exec of
        undefined ->
            %% A buffered tool call may name a server tool; if so, run
            %% it and continue the turn instead of finishing.
            maybe_server_tool_or_finish(Req, demonitor_engine(S1));
        _ ->
            {ok, Req, demonitor_engine(S1), hibernate}
    end;
info({tool_exec_result, CallId, Result}, Req, S = #st{pending_exec = #{call_id := CallId}}) ->
    continue_after_tool(Result, Req, S);
info({tool_exec_result, _, _}, Req, S) ->
    {ok, Req, S, hibernate};
info({exec_timeout, CallId}, Req, S = #st{pending_exec = #{call_id := CallId}}) ->
    continue_after_tool({error, executor_timeout}, Req, S);
info({exec_timeout, _}, Req, S) ->
    {ok, Req, S, hibernate};
info({'DOWN', Mon, process, _Pid, normal}, Req, S = #st{exec_mon = Mon}) ->
    {ok, Req, S#st{exec_mon = undefined}, hibernate};
info({'DOWN', Mon, process, _Pid, Reason}, Req, S = #st{exec_mon = Mon, pending_exec = P}) when
    P =/= undefined
->
    continue_after_tool({error, {executor_crashed, Reason}}, Req, S);
info({erllama_error, Ref, Reason}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_err(Req, demonitor_engine(S#st{received_done = true}), Reason);
%% --- timeouts ---
info({prefill_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    erllama:cancel(Ref),
    finish_err(Req, S, prefill_timeout);
info({idle_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    erllama:cancel(Ref),
    finish_err(Req, S, generation_idle_timeout);
info(total_request_timeout, Req, S = #st{phase = running, ref = Ref}) when is_reference(Ref) ->
    erllama:cancel(Ref),
    finish_err(Req, S, total_timeout);
info(total_request_timeout, Req0, S) ->
    %% Fired before admission. No SSE has started; reply with a JSON
    %% 504 and let terminate/3 clean up the worker.
    Req1 = json_error(504, total_timeout, Req0),
    record_metrics(S, 504),
    {stop, Req1, S};
%% erllama 0.2.0 emits a token-id message alongside every token text
%% message. We do not consume it.
info({erllama_token_id, _Ref, _Id}, Req, S) ->
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
        true -> erllama_server_pipeline:abort(S#st.worker);
        false -> ok
    end,
    case S#st.ref of
        Ref when is_reference(Ref) -> erllama:cancel(Ref);
        _ -> ok
    end,
    case S#st.slot of
        undefined -> ok;
        Slot -> erllama_server_queue:release(S#st.model, Slot)
    end,
    case S#st.grammar_set of
        %% cleared by erllama_model on finish_request
        true -> ok;
        false -> ok
    end,
    %% Cancelled mid-flight: free the pinned session so the next
    %% request can admit. Naturally-completed turns leave the session
    %% alive for cross-turn KV reuse. Mirrors erllama_server_h_messages.
    maybe_end_session(S),
    %% Decrement the keepalive active count. If this was the last
    %% request, the model enters the keep-alive grace window.
    keepalive_release(S),
    erllama_server_metrics:dec_active_streams(S#st.model).

maybe_end_session(#st{received_done = true}) ->
    ok;
maybe_end_session(#st{session_id = undefined}) ->
    ok;
maybe_end_session(#st{model = Model, session_id = SessionId}) ->
    try
        erllama:end_session(Model, SessionId)
    catch
        _:_ -> ok
    end,
    erllama_server_session_state:delete(Model, SessionId),
    ok.

record_session_committed(#st{session_id = undefined}, _) ->
    ok;
record_session_committed(#st{model = Model, session_id = SessionId}, Stats) ->
    case maps:get(committed_tokens, Stats, undefined) of
        N when is_integer(N), N > 0 ->
            erllama_server_session_state:put(Model, SessionId, N);
        _ ->
            ok
    end.

%% Balance request_begin iff it ran. Keying off `keepalive_begun`
%% (not phase) is correct under the loop, where a re-load round resets
%% phase to waiting_load while the begin is still outstanding.
keepalive_release(#st{keepalive_begun = false}) ->
    ok;
keepalive_release(#st{model = Model}) ->
    erllama_server_keepalive:request_end(
        Model, erllama_server_config:keep_alive_default_ms()
    ).

%%====================================================================
%% Token handling
%%====================================================================

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

emit_text(Tok, Req, S = #st{stream = true}) ->
    Iolist = erllama_server_translate:internal_to_openai_chat_chunk(
        Tok, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body([<<"data: ">>, Iolist, <<"\n\n">>], nofin, Req),
    {ok, Req, rearm_idle(S#st{out_tokens = S#st.out_tokens + 1}), hibernate};
emit_text(Tok, Req, S = #st{stream = false}) ->
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text | Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate}.

handle_reasoning(Tok, Req, S = #st{stream = true}) ->
    Iolist = erllama_server_translate:internal_to_openai_reasoning_chunk(
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
    Final = erllama_server_translate:internal_to_openai_chat_final(
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
    Stop = erllama_server_translate:internal_to_openai_chat_final(
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
                erllama_server_translate:internal_to_openai_completion_response(
                    Text, Stats, S#st.requested
                );
            _ ->
                erllama_server_translate:internal_to_openai_chat_response(
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
    erllama_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    arm_idle_timer(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

arm_prefill_timer(S) ->
    Ms = erllama_server_config:prefill_ms(),
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
    Ms = erllama_server_config:generation_idle_ms(),
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
    case erllama_server_config:total_ms() of
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

%% Mirror of erllama_server_h_messages: monitor the engine on admit
%% so a NIF / gen_statem crash mid-inference surfaces cleanly.
monitor_engine(S = #st{engine_mon = Mon}) when is_reference(Mon) ->
    S;
monitor_engine(S = #st{model = Model}) ->
    case erllama_registry:whereis_name(Model) of
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
    erllama_server_metrics:inc_prompt_tokens(
        S#st.model,
        maps:get(prompt_tokens, Stats, 0)
    ),
    erllama_server_metrics:inc_completion_tokens(
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
                    erllama_server_metrics:observe_generation_tps(S#st.model, Tps);
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
    erllama_server_metrics:record_request(
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
    Chunk = erllama_server_translate:internal_to_openai_usage_chunk(
        Stats, S#st.req_id, S#st.requested
    ),
    [<<"data: ">>, Chunk, <<"\n\n">>].

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

%% Prefer the v0.5 wire-captured tool_use when present; otherwise
%% fall back to parsing the legacy buf_text JSON.
extract_tool_call(#st{captured_tool_use = #{id := Id, name := N, input := I}}, _) ->
    {N, iolist_to_binary(json:encode(I)), Id};
extract_tool_call(_S, JsonBin) ->
    {Nm, Args} = parse_tool_call(JsonBin),
    {Nm, Args, make_tool_id()}.

%% erllama 0.5.0 wire entry point: parse FullBin via the per-model
%% format module, mint a tool id, persist for next-turn exact replay,
%% and stash the captured block on #st so finish_ok's existing
%% tool_buffer clause emits the chat.completion.chunk shape.
handle_tool_call_end(FullBin, Req, S = #st{tool_format = Spec, model = Model}) ->
    {Name, Input} = parse_full_bin(Spec, FullBin),
    ToolId = make_tool_id_toolu(),
    maybe_persist_replay(Spec, ToolId, Model, FullBin, Name, Input),
    Captured = #{id => ToolId, name => Name, input => Input},
    %% Keep the verbatim bytes in buf_text too: the server-tool loop
    %% feeds them back as the assistant turn (extract_tool_call still
    %% prefers captured_tool_use, so the client-tool finish is
    %% unaffected).
    {ok, Req,
        rearm_idle(S#st{
            mode = tool_buffer,
            buf_text = [FullBin],
            captured_tool_use = Captured
        }), hibernate}.

%% Parses FullBin to a `{Name, ArgsMap}' pair via the format module,
%% with a fall-back to the in-line `parse_tool_call/1' (which returns
%% a JSON string for arguments). When falling back, decode the JSON
%% so the captured `input' stays a map.
parse_full_bin(undefined, FullBin) ->
    parse_tool_call_to_map(FullBin);
parse_full_bin(Spec, FullBin) ->
    case erllama_server_tool_format:parse(Spec, FullBin) of
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
    erllama_server_tool_replay:put(
        ToolId,
        Model,
        FullBin,
        #{name => Name, arguments => Input}
    ).

%%====================================================================
%% Agentic continue-loop (server-executed built-in tools)
%%====================================================================

%% At done, a buffered tool call (wire or legacy) may name a server
%% tool. If so, run the executor and continue the turn; otherwise
%% finish normally (a client tool_calls chunk or plain text).
maybe_server_tool_or_finish(Req, S = #st{mode = tool_buffer, server_tools = ST}) when
    map_size(ST) > 0
->
    {Name, Input} = tool_name_input(S),
    case maps:find(Name, ST) of
        {ok, ExecSpec} ->
            begin_server_tool(iolist_to_binary(S#st.buf_text), Name, Input, ExecSpec, Req, S);
        error ->
            finish_ok(Req, S#st{received_done = true}, S#st.agg_stats)
    end;
maybe_server_tool_or_finish(Req, S) ->
    finish_ok(Req, S#st{received_done = true}, S#st.agg_stats).

tool_name_input(#st{captured_tool_use = #{name := N, input := I}}) ->
    {N, I};
tool_name_input(#st{buf_text = B}) ->
    parse_tool_call_to_map(iolist_to_binary(B)).

%% Run the executor off the handler process; the result arrives as a
%% {tool_exec_result, CallId, _} message.
begin_server_tool(FullBin, Name, Input, ExecSpec, Req, S) ->
    CallId = erllama_server_translate:make_id(<<"call_">>),
    Self = self(),
    Ctx = #{
        model => S#st.model,
        request_id => S#st.req_id,
        session_id => S#st.session_id,
        config => maps:without([module, type], ExecSpec)
    },
    {_Pid, Mon} = spawn_monitor(fun() ->
        Self ! {tool_exec_result, CallId, run_executor(ExecSpec, Input, Ctx)}
    end),
    TRef = erlang:send_after(exec_timeout_ms(), self(), {exec_timeout, CallId}),
    Pending = #{
        spec => ExecSpec,
        name => Name,
        args => Input,
        call_id => CallId,
        full_bin => FullBin
    },
    cancel_timer(S#st.idle_tref),
    {ok, Req, S#st{pending_exec = Pending, exec_mon = Mon, exec_tref = TRef, idle_tref = undefined},
        hibernate}.

run_executor(ExecSpec, Input, Ctx) ->
    try
        erllama_server_tool_executor:execute(ExecSpec, Input, Ctx)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Fold the result into the conversation and re-invoke on the warm
%% session path (session_id kept), streaming into the same response.
continue_after_tool(Result, Req, S0) ->
    #{name := _Name, call_id := CallId, full_bin := FullBin} = S0#st.pending_exec,
    S = clear_pending(S0),
    Iter = S#st.tool_iter + 1,
    ResultJson = result_json(Result),
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_ok(
                Req,
                S#st{received_done = true, tool_iter = Iter, mode = text, buf_text = []},
                Stats
            );
        false ->
            NewMessages =
                S#st.loop_messages ++
                    [
                        #{role => <<"assistant">>, content => FullBin},
                        #{
                            role => <<"tool">>,
                            content =>
                                <<"[tool_result id=", CallId/binary, "]: ", ResultJson/binary>>
                        }
                    ],
            ContReq = (S#st.loop_request)#erllama_request{messages = NewMessages},
            release_slot(S),
            {WorkerPid, Mon} = erllama_server_pipeline:start_link(self(), ContReq),
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
                %% Reset so the next round's first-byte detection fires;
                %% otherwise a round-2 tool call streams as plain text.
                out_tokens = 0,
                captured_tool_use = undefined,
                first_token_at = undefined
            },
            {ok, Req, S2, hibernate}
    end.

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
    erllama_server_queue:release(Model, Slot).

result_json({ok, Json}) when is_map(Json) ->
    iolist_to_binary(json:encode(Json));
result_json({ok, Bin}) when is_binary(Bin) ->
    Bin;
result_json({error, Reason}) ->
    iolist_to_binary(json:encode(#{<<"error">> => to_bin(Reason)})).

exec_timeout_ms() ->
    erllama_server_config:generation_idle_ms().

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
