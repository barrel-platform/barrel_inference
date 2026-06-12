%%% Livery-side handler for /v1/chat/completions and /v1/completions.
%%%
%%% Coexists with `barrel_inference_server_h_chat' during the cowboy →
%%% livery migration. Mirrors the request/response shape exactly; only
%%% the framework call surface differs.
%%%
%%% Uses `livery_resp:stream/3' with manual SSE framing for full
%%% control over comments, multi-frame finishes, and `[DONE]'.

-module(barrel_inference_server_h_chat_livery).

-export([openai/1, legacy/1]).

%% The receive-loop driven state mutates `ref' / `slot' / `pending_exec'
%% through pipeline messages dialyzer can't trace through. The cleanup
%% paths legitimately pattern-match both shapes; suppress narrowing.
-dialyzer(
    {nowarn_function, [
        cleanup/1,
        keepalive_release/1,
        maybe_end_session/1,
        record_session_committed/2,
        release_slot/1,
        drive_stream/4,
        drive_buffered/3
    ]}
).

-include("barrel_inference_server.hrl").

-record(st, {
    req_id :: binary(),
    model :: binary(),
    requested :: binary(),
    api :: openai | openai_legacy,
    stream :: boolean(),
    phase ::
        waiting_load
        | waiting_template
        | waiting_queue
        | waiting_admit
        | running,
    worker :: pid() | undefined,
    worker_mon :: reference() | undefined,
    engine_mon :: reference() | undefined,
    ref :: reference() | undefined,
    slot :: barrel_inference_server_queue:slot() | undefined,
    started_mono :: integer(),
    first_token_at :: integer() | undefined,
    prefill_tref :: reference() | undefined,
    idle_tref :: reference() | undefined,
    total_tref :: reference() | undefined,
    out_tokens :: non_neg_integer(),
    buf_text :: iodata(),
    buf_reason :: iodata(),
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    include_usage = false :: boolean(),
    stream_started = false :: boolean(),
    received_done = false :: boolean(),
    session_id = undefined :: undefined | binary(),
    chat_params_ref = undefined :: undefined | barrel_inference_nif:chat_params_ref(),
    captured_calls = [] ::
        [#{id := binary(), name := binary(), input := map(), full_bin := binary()}],
    server_tools = #{} :: #{binary() => barrel_inference_server_tool_executor:spec()},
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
    keepalive_begun = false :: boolean(),
    prompt_token_ids = [] :: [non_neg_integer()]
}).

%%====================================================================
%% Entry points
%%====================================================================

openai(Req) -> handle(Req, openai).
legacy(Req) -> handle(Req, openai_legacy).

handle(Req, Api) ->
    case livery_req:method(Req) of
        <<"POST">> -> handle_post(Req, Api);
        _ -> livery_resp:json(405, json:encode(error_body(method_not_allowed, 405)))
    end.

handle_post(Req, Api) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Body, Req1} -> fast_phase(Body, Api, Req1);
        {too_large, _Req1} -> livery_resp:json(413, json:encode(error_body(request_too_large, 413)))
    end.

fast_phase(Body, Api, Req) ->
    case decode(Body) of
        {ok, Map} -> translate(Map, Api, Req);
        error -> livery_resp:json(400, json:encode(error_body(invalid_json, 400)))
    end.

translate(Map, Api, Req) ->
    Translated =
        case Api of
            openai_legacy ->
                barrel_inference_server_translate:openai_completion_to_internal(Map);
            _ ->
                barrel_inference_server_translate:openai_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R0} ->
            R1 = R0#barrel_inference_request{
                session_id = barrel_inference_server_session:derive(Req, R0)
            },
            start_inference(R1, Api);
        {error, Reason} ->
            livery_resp:json(400, json:encode(error_body(Reason, 400)))
    end.

start_inference(R0, Api) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    case R1#barrel_inference_request.stream of
        true ->
            livery_resp:stream(
                200,
                sse_headers(),
                fun(Emit) -> drive_stream(R1, Requested, Api, Emit) end
            );
        false ->
            drive_buffered(R1, Requested, Api)
    end.

drive_stream(R, Requested, Api, Emit) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(R, Requested, Api, Worker, Mon, true),
    State1 = arm_total_timer(State),
    _ =
        try
            stream_loop(State1, Emit)
        after
            cleanup(State1)
        end,
    ok.

drive_buffered(R, Requested, Api) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(R, Requested, Api, Worker, Mon, false),
    State1 = arm_total_timer(State),
    try
        buffered_loop(State1)
    after
        cleanup(State1)
    end.

init_state(R, Requested, Api, Worker, Mon, Stream) ->
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
        started_mono = mono_ms(),
        out_tokens = 0,
        buf_text = [],
        buf_reason = [],
        mode = text,
        grammar_set = grammar_active(R),
        include_usage = R#barrel_inference_request.include_usage,
        session_id = R#barrel_inference_request.session_id,
        server_tools = R#barrel_inference_request.server_tools,
        max_tool_iter = barrel_inference_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#barrel_inference_request.messages
    }.

grammar_active(#barrel_inference_request{tools = Tools, tool_choice = TC}) ->
    case {Tools, TC} of
        {undefined, _} -> false;
        {[], _} -> false;
        {_, none} -> false;
        _ -> true
    end.

%%====================================================================
%% Streaming receive loop
%%====================================================================

stream_loop(S, Emit) ->
    receive
        Msg -> dispatch_stream(Msg, S, Emit)
    after stream_idle_timeout() -> S
    end.

dispatch_stream({pipeline, _} = M, S, Emit) -> on_pipeline_stream(M, S, Emit);
dispatch_stream({pipeline, _, _} = M, S, Emit) -> on_pipeline_stream(M, S, Emit);
dispatch_stream({pipeline, _, _, _} = M, S, Emit) -> on_pipeline_stream(M, S, Emit);
dispatch_stream({barrel_inference_token, Ref, Tok}, S, Emit) ->
    on_stream_token(S, Ref, Tok, Emit);
dispatch_stream({barrel_inference_reasoning_token, Ref, Tok}, S, Emit) ->
    on_stream_reasoning(S, Ref, Tok, Emit);
dispatch_stream({barrel_inference_done, Ref, Stats}, S, Emit) ->
    on_stream_done(S, Ref, Stats, Emit);
dispatch_stream({barrel_inference_error, Ref, Reason}, S, Emit) ->
    on_stream_engine_error(S, Ref, Reason, Emit);
dispatch_stream({tool_exec_batch_result, BR, Results}, S, Emit) when
    is_map(S#st.pending_exec), map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results(Results, S, Emit, true);
dispatch_stream({exec_timeout, BR}, S, Emit) when
    is_map(S#st.pending_exec), map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results({error, executor_timeout}, S, Emit, true);
dispatch_stream({'DOWN', Mon, process, _Pid, Reason}, S, Emit) when
    Mon =:= S#st.engine_mon
->
    finish_stream_err(S#st{engine_mon = undefined}, model_crashed_from(Reason), Emit);
dispatch_stream({'DOWN', Mon, process, _Pid, normal}, S, Emit) when
    Mon =:= S#st.worker_mon
->
    stream_loop(S#st{worker = undefined, worker_mon = undefined}, Emit);
dispatch_stream({'DOWN', Mon, process, _Pid, _Reason}, S, Emit) when
    Mon =:= S#st.exec_mon
->
    stream_loop(S#st{exec_mon = undefined}, Emit);
dispatch_stream({prefill_timeout, Ref}, S, Emit) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, prefill_timeout, Emit);
dispatch_stream({idle_timeout, Ref}, S, Emit) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, generation_idle_timeout, Emit);
dispatch_stream(total_request_timeout, S, Emit) ->
    on_total_timeout(S, Emit);
dispatch_stream(_Other, S, Emit) ->
    stream_loop(S, Emit).

on_pipeline_stream({pipeline, loading, _M}, S, Emit) ->
    case emit_raw(Emit, [<<": loading\n\n">>]) of
        ok -> stream_loop(S#st{stream_started = true}, Emit);
        closed -> S
    end;
on_pipeline_stream({pipeline, loaded}, S = #st{keepalive_begun = true}, Emit) ->
    stream_loop(S#st{phase = waiting_template}, Emit);
on_pipeline_stream({pipeline, loaded}, S, Emit) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    stream_loop(S#st{phase = waiting_template, keepalive_begun = true}, Emit);
on_pipeline_stream({pipeline, templated, Tokens, ParamsRef}, S, Emit) ->
    stream_loop(
        S#st{phase = waiting_queue, prompt_token_ids = Tokens, chat_params_ref = ParamsRef},
        Emit
    );
on_pipeline_stream({pipeline, queued}, S, Emit) ->
    stream_loop(S#st{phase = waiting_admit}, Emit);
on_pipeline_stream({pipeline, admitted, Ref, Slot}, S, Emit) ->
    S1 = monitor_engine(arm_prefill_timer(S#st{phase = running, ref = Ref, slot = Slot})),
    stream_loop(S1, Emit);
on_pipeline_stream({pipeline, error, Status, Reason}, S, Emit) ->
    record_metrics(S, Status),
    Err = json:encode(error_body(Reason, Status)),
    _ = emit_raw(Emit, [<<"data: ">>, Err, <<"\n\n">>, <<"data: [DONE]\n\n">>]),
    S.

on_stream_token(S0, Ref, Tok, Emit) ->
    S = learn_ref(S0, Ref),
    case handle_token_stream(Tok, S) of
        {emit, Out, S1} ->
            case emit_raw(Emit, Out) of
                ok -> stream_loop(rearm_idle(S1), Emit);
                closed -> S1
            end;
        {buffer, S1} ->
            stream_loop(rearm_idle(S1), Emit)
    end.

handle_token_stream(Tok, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    case is_tool_first_byte(Tok) of
        true ->
            {buffer, first_token(S#st{
                mode = tool_buffer, buf_text = [Tok], out_tokens = 1
            })};
        false ->
            stream_text_first(Tok, first_token(S))
    end;
handle_token_stream(Tok, S = #st{mode = tool_buffer}) ->
    {buffer, S#st{
        buf_text = [S#st.buf_text | Tok],
        out_tokens = S#st.out_tokens + 1
    }};
handle_token_stream(Tok, S = #st{out_tokens = 0}) ->
    stream_text_first(Tok, first_token(S));
handle_token_stream(Tok, S) ->
    stream_text_more(Tok, S).

stream_text_first(Tok, S) -> stream_text_more(Tok, S).
stream_text_more(Tok, S) ->
    Iolist = barrel_inference_server_translate:internal_to_openai_chat_chunk(
        Tok, S#st.req_id, S#st.requested
    ),
    {emit, [<<"data: ">>, Iolist, <<"\n\n">>], S#st{out_tokens = S#st.out_tokens + 1}}.

on_stream_reasoning(S0, Ref, Tok, Emit) ->
    S = learn_ref(S0, Ref),
    Iolist = barrel_inference_server_translate:internal_to_openai_reasoning_chunk(
        Tok, S#st.req_id, S#st.requested
    ),
    case emit_raw(Emit, [<<"data: ">>, Iolist, <<"\n\n">>]) of
        ok -> stream_loop(rearm_idle(S), Emit);
        closed -> S
    end.

on_stream_done(S0, Ref, Stats, Emit) ->
    S = learn_ref(S0, Ref),
    record_session_committed(S, Stats),
    S1 = demonitor_engine(accumulate_stats(S, Stats)),
    S2 = maybe_autoparser_extract(S1),
    dispatch_done_stream(S2, Emit).

dispatch_done_stream(S = #st{captured_calls = []}, Emit) ->
    maybe_legacy_tool_stream(S, Emit);
dispatch_done_stream(S = #st{captured_calls = Calls0}, Emit) ->
    Calls = cap_parallel(S, Calls0),
    {ServerCalls, ClientCalls} = partition_calls(Calls, S#st.server_tools),
    case ServerCalls of
        [] -> finish_with_tool_calls_stream(S#st{received_done = true}, ClientCalls, Emit);
        _ -> begin_server_tools_stream(ServerCalls, S, Emit)
    end.

maybe_legacy_tool_stream(S = #st{mode = tool_buffer, server_tools = ST}, Emit) when
    map_size(ST) > 0
->
    {Name, Input} = parse_tool_call_to_map(iolist_to_binary(S#st.buf_text)),
    case maps:find(Name, ST) of
        {ok, _} ->
            Call = #{
                id => barrel_inference_server_translate:make_id(<<"call_">>),
                name => Name,
                input => Input,
                full_bin => iolist_to_binary(S#st.buf_text)
            },
            begin_server_tools_stream([Call], S, Emit);
        error ->
            finish_stream_ok(S#st{received_done = true}, S#st.agg_stats, Emit)
    end;
maybe_legacy_tool_stream(S, Emit) ->
    finish_stream_ok(S#st{received_done = true}, S#st.agg_stats, Emit).

finish_stream_ok(S = #st{mode = text}, Stats, Emit) ->
    Final = barrel_inference_server_translate:internal_to_openai_chat_final(
        Stats, S#st.req_id, S#st.requested
    ),
    Frames = [
        <<"data: ">>, Final, <<"\n\n">>,
        usage_chunk(S, Stats),
        <<"data: [DONE]\n\n">>
    ],
    _ = emit_raw(Emit, Frames),
    record_success(S, Stats),
    S;
finish_stream_ok(S = #st{mode = tool_buffer}, Stats, Emit) ->
    ToolStats = maps:put(finish_reason, tool_call, Stats),
    First = openai_tool_call_chunk(S, iolist_to_binary(S#st.buf_text)),
    Stop = barrel_inference_server_translate:internal_to_openai_chat_final(
        ToolStats, S#st.req_id, S#st.requested
    ),
    Frames = [
        <<"data: ">>, First, <<"\n\n">>,
        <<"data: ">>, Stop, <<"\n\n">>,
        usage_chunk(S, ToolStats),
        <<"data: [DONE]\n\n">>
    ],
    _ = emit_raw(Emit, Frames),
    record_success(S, Stats),
    S.

finish_with_tool_calls_stream(S, Calls, Emit) ->
    ToolStats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    First = openai_tool_calls_chunk(S, Calls),
    Stop = barrel_inference_server_translate:internal_to_openai_chat_final(
        ToolStats, S#st.req_id, S#st.requested
    ),
    Frames = [
        <<"data: ">>, First, <<"\n\n">>,
        <<"data: ">>, Stop, <<"\n\n">>,
        usage_chunk(S, ToolStats),
        <<"data: [DONE]\n\n">>
    ],
    _ = emit_raw(Emit, Frames),
    record_success(S, ToolStats),
    S.

finish_stream_err(S, Reason, Emit) ->
    Status = http_status(Reason),
    Err = json:encode(error_body(Reason, Status)),
    _ = emit_raw(Emit, [<<"data: ">>, Err, <<"\n\n">>, <<"data: [DONE]\n\n">>]),
    record_error(S, Reason),
    S.

on_stream_engine_error(S0, Ref, Reason, Emit) ->
    S = learn_ref(S0, Ref),
    finish_stream_err(demonitor_engine(S#st{received_done = true}), Reason, Emit).

on_total_timeout(S = #st{ref = Ref}, Emit) when is_reference(Ref) ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, total_timeout, Emit);
on_total_timeout(S, Emit) ->
    finish_stream_err(S, total_timeout, Emit).

%% Re-enter inference for the continue-loop on the same handler process.
on_tool_results(Outcome, S0, Emit, true) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_stream_ok(
                S#st{
                    received_done = true, tool_iter = Iter,
                    mode = text, buf_text = []
                },
                Stats,
                Emit
            );
        false ->
            S1 = restart_round(Calls, Outcome, S),
            stream_loop(S1, Emit)
    end.

restart_round(Calls, Outcome, S) ->
    NewMessages = S#st.loop_messages ++ tool_round_messages(Calls, Outcome),
    ContReq = (S#st.loop_request)#barrel_inference_request{messages = NewMessages},
    release_slot(S),
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), ContReq),
    S#st{
        tool_iter = S#st.tool_iter + 1,
        loop_messages = NewMessages,
        worker = Worker,
        worker_mon = Mon,
        phase = waiting_load,
        ref = undefined,
        slot = undefined,
        mode = text,
        buf_text = [],
        out_tokens = 0,
        captured_calls = [],
        first_token_at = undefined
    }.

begin_server_tools_stream(ServerCalls, S, Emit) ->
    S1 = begin_server_tools_common(ServerCalls, S),
    stream_loop(S1, Emit).

begin_server_tools_common(ServerCalls, S) ->
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
    S#st{
        pending_exec = Pending,
        exec_mon = Mon,
        exec_tref = TRef,
        idle_tref = undefined,
        captured_calls = []
    }.

%%====================================================================
%% Buffered (non-stream) receive loop
%%====================================================================

buffered_loop(S) ->
    receive
        Msg -> dispatch_buffered(Msg, S)
    after stream_idle_timeout() ->
        livery_resp:json(504, json:encode(error_body(idle_timeout, 504)))
    end.

dispatch_buffered({pipeline, _} = M, S) -> on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _} = M, S) -> on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _, _} = M, S) -> on_pipeline_buffered(M, S);
dispatch_buffered({barrel_inference_token, Ref, Tok}, S) ->
    S1 = learn_ref(S, Ref),
    {cont, S2} = handle_token_buffered(Tok, S1),
    buffered_loop(rearm_idle(S2));
dispatch_buffered({barrel_inference_reasoning_token, Ref, Tok}, S) ->
    S1 = learn_ref(S, Ref),
    buffered_loop(rearm_idle(S1#st{buf_reason = [S1#st.buf_reason | Tok]}));
dispatch_buffered({barrel_inference_done, Ref, Stats}, S) ->
    on_done_buffered(learn_ref(S, Ref), Stats);
dispatch_buffered({barrel_inference_error, _Ref, Reason}, S) ->
    record_error(S, Reason),
    finish_err_buffered(Reason);
dispatch_buffered({tool_exec_batch_result, BR, Results}, S) when
    is_map(S#st.pending_exec), map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results_buffered(Results, S);
dispatch_buffered({exec_timeout, BR}, S) when
    is_map(S#st.pending_exec), map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results_buffered({error, executor_timeout}, S);
dispatch_buffered({'DOWN', Mon, process, _Pid, normal}, S) when
    Mon =:= S#st.worker_mon
->
    buffered_loop(S#st{worker = undefined, worker_mon = undefined});
dispatch_buffered({'DOWN', Mon, process, _Pid, _R}, S) when
    Mon =:= S#st.exec_mon
->
    buffered_loop(S#st{exec_mon = undefined});
dispatch_buffered({prefill_timeout, Ref}, S) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_err_buffered(prefill_timeout);
dispatch_buffered({idle_timeout, Ref}, S) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_err_buffered(generation_idle_timeout);
dispatch_buffered(total_request_timeout, S) ->
    case S#st.ref of
        Ref when is_reference(Ref) -> barrel_inference:cancel(Ref);
        _ -> ok
    end,
    finish_err_buffered(total_timeout);
dispatch_buffered(_Other, S) ->
    buffered_loop(S).

on_pipeline_buffered({pipeline, loading, _M}, S) -> buffered_loop(S);
on_pipeline_buffered({pipeline, loaded}, S = #st{keepalive_begun = true}) ->
    buffered_loop(S#st{phase = waiting_template});
on_pipeline_buffered({pipeline, loaded}, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    buffered_loop(S#st{phase = waiting_template, keepalive_begun = true});
on_pipeline_buffered({pipeline, templated, Tokens, ParamsRef}, S) ->
    buffered_loop(S#st{
        phase = waiting_queue, prompt_token_ids = Tokens, chat_params_ref = ParamsRef
    });
on_pipeline_buffered({pipeline, queued}, S) ->
    buffered_loop(S#st{phase = waiting_admit});
on_pipeline_buffered({pipeline, admitted, Ref, Slot}, S) ->
    S1 = monitor_engine(arm_prefill_timer(S#st{phase = running, ref = Ref, slot = Slot})),
    buffered_loop(S1);
on_pipeline_buffered({pipeline, error, Status, Reason}, _S) ->
    livery_resp:json(Status, json:encode(error_body(Reason, Status))).

handle_token_buffered(Tok, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    case is_tool_first_byte(Tok) of
        true ->
            {cont, first_token(S#st{
                mode = tool_buffer, buf_text = [Tok], out_tokens = 1
            })};
        false ->
            {cont, first_token(S#st{
                buf_text = [S#st.buf_text | Tok], out_tokens = 1
            })}
    end;
handle_token_buffered(Tok, S = #st{out_tokens = 0}) ->
    {cont, first_token(S#st{
        buf_text = [S#st.buf_text | Tok], out_tokens = 1
    })};
handle_token_buffered(Tok, S) ->
    {cont, S#st{
        buf_text = [S#st.buf_text | Tok], out_tokens = S#st.out_tokens + 1
    }}.

on_done_buffered(S0, Stats) ->
    record_session_committed(S0, Stats),
    S1 = demonitor_engine(accumulate_stats(S0, Stats)),
    S2 = maybe_autoparser_extract(S1),
    dispatch_done_buffered(S2).

dispatch_done_buffered(S = #st{captured_calls = []}) ->
    maybe_legacy_tool_buffered(S);
dispatch_done_buffered(S = #st{captured_calls = Calls0}) ->
    Calls = cap_parallel(S, Calls0),
    {ServerCalls, ClientCalls} = partition_calls(Calls, S#st.server_tools),
    case ServerCalls of
        [] -> finish_with_tool_calls_buffered(S#st{received_done = true}, ClientCalls);
        _ -> begin_server_tools_buffered(ServerCalls, S)
    end.

maybe_legacy_tool_buffered(S = #st{mode = tool_buffer, server_tools = ST}) when
    map_size(ST) > 0
->
    {Name, Input} = parse_tool_call_to_map(iolist_to_binary(S#st.buf_text)),
    case maps:find(Name, ST) of
        {ok, _} ->
            Call = #{
                id => barrel_inference_server_translate:make_id(<<"call_">>),
                name => Name,
                input => Input,
                full_bin => iolist_to_binary(S#st.buf_text)
            },
            begin_server_tools_buffered([Call], S);
        error ->
            finish_ok_buffered(S#st{received_done = true}, S#st.agg_stats)
    end;
maybe_legacy_tool_buffered(S) ->
    finish_ok_buffered(S#st{received_done = true}, S#st.agg_stats).

finish_ok_buffered(S = #st{api = Api}, Stats) ->
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
    record_success(S, Stats),
    livery_resp:json(200, json:encode(Body)).

finish_with_tool_calls_buffered(S, Calls) ->
    Stats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    Body = barrel_inference_server_translate:internal_to_openai_chat_tool_calls_response(
        Calls, Stats, S#st.requested
    ),
    record_success(S, Stats),
    livery_resp:json(200, json:encode(Body)).

finish_err_buffered(Reason) ->
    Status = http_status(Reason),
    livery_resp:json(Status, json:encode(error_body(Reason, Status))).

begin_server_tools_buffered(ServerCalls, S) ->
    S1 = begin_server_tools_common(ServerCalls, S),
    buffered_loop(S1).

on_tool_results_buffered(Outcome, S0) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_ok_buffered(
                S#st{received_done = true, tool_iter = Iter, mode = text, buf_text = []},
                Stats
            );
        false ->
            buffered_loop(restart_round(Calls, Outcome, S))
    end.

%%====================================================================
%% Shared helpers
%%====================================================================

learn_ref(S = #st{ref = undefined}, Ref) ->
    arm_prefill_timer(S#st{phase = running, ref = Ref});
learn_ref(S, _Ref) ->
    S.

first_token(S = #st{first_token_at = undefined}) ->
    Now = mono_ms(),
    PrefillSec = (Now - S#st.started_mono) / 1000.0,
    barrel_inference_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    arm_idle_timer(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

arm_prefill_timer(S = #st{ref = undefined}) ->
    S;
arm_prefill_timer(S = #st{ref = Ref}) ->
    Ms = barrel_inference_server_config:prefill_ms(),
    S#st{prefill_tref = erlang:send_after(Ms, self(), {prefill_timeout, Ref})}.

arm_idle_timer(S) -> rearm_idle(S).

rearm_idle(S) ->
    cancel_timer(S#st.idle_tref),
    case S#st.ref of
        undefined ->
            S;
        Ref ->
            Ms = barrel_inference_server_config:generation_idle_ms(),
            S#st{idle_tref = erlang:send_after(Ms, self(), {idle_timeout, Ref})}
    end.

arm_total_timer(S) ->
    Ms = total_ms(),
    S#st{total_tref = erlang:send_after(Ms, self(), total_request_timeout)}.

total_ms() ->
    case barrel_inference_server_config:total_ms() of
        N when is_integer(N), N > 0 -> N;
        _ -> 1800000
    end.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> _ = erlang:cancel_timer(Ref), ok.

monitor_engine(S = #st{engine_mon = Mon}) when is_reference(Mon) -> S;
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
    release_slot(S),
    maybe_end_session(S),
    keepalive_release(S),
    barrel_inference_server_metrics:dec_active_streams(S#st.model).

release_slot(#st{slot = undefined}) -> ok;
release_slot(#st{model = Model, slot = Slot}) ->
    barrel_inference_server_queue:release(Model, Slot).

maybe_end_session(#st{received_done = true}) -> ok;
maybe_end_session(#st{session_id = undefined}) -> ok;
maybe_end_session(#st{model = Model, session_id = SessionId}) ->
    try
        barrel_inference:end_session(Model, SessionId)
    catch
        _:_ -> ok
    end,
    barrel_inference_server_session_state:delete(Model, SessionId),
    ok.

keepalive_release(#st{keepalive_begun = false}) -> ok;
keepalive_release(#st{model = Model}) ->
    barrel_inference_server_keepalive:request_end(
        Model, barrel_inference_server_config:keep_alive_default_ms()
    ).

record_session_committed(#st{session_id = undefined}, _) ->
    ok;
record_session_committed(S, Stats) ->
    barrel_inference_server_session_state:record(
        S#st.model, S#st.session_id, S#st.prompt_token_ids, Stats
    ).

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

clear_pending(S) ->
    case S#st.exec_mon of
        Mon when is_reference(Mon) -> erlang:demonitor(Mon, [flush]);
        _ -> ok
    end,
    cancel_timer(S#st.exec_tref),
    S#st{pending_exec = undefined, exec_mon = undefined, exec_tref = undefined}.

%%====================================================================
%% Tool-call helpers
%%====================================================================

cap_parallel(#st{loop_request = #barrel_inference_request{parallel_tool_calls = false}}, Calls) ->
    lists:sublist(Calls, 1);
cap_parallel(_S, Calls) ->
    Calls.

partition_calls(Calls, ServerTools) ->
    lists:partition(fun(#{name := N}) -> maps:is_key(N, ServerTools) end, Calls).

maybe_autoparser_extract(S = #st{buf_text = BufText, chat_params_ref = ParamsRef}) when
    S#st.loop_request =/= undefined
->
    case
        barrel_inference_server_autoparser:maybe_extract(
            ParamsRef, S#st.loop_request, BufText, openai
        )
    of
        {ok, Calls} ->
            S#st{captured_calls = S#st.captured_calls ++ Calls, buf_text = []};
        none ->
            S
    end;
maybe_autoparser_extract(S) ->
    S.

parse_tool_call_to_map(JsonBin) when is_binary(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} when is_map(Args) ->
            {Name, Args};
        _ ->
            {<<"unknown">>, #{}}
    catch
        _:_ -> {<<"unknown">>, #{}}
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

result_json({ok, Json}) when is_map(Json) -> iolist_to_binary(json:encode(Json));
result_json({ok, Bin}) when is_binary(Bin) -> Bin;
result_json({error, Reason}) ->
    iolist_to_binary(json:encode(#{<<"error">> => to_bin(Reason)})).

exec_timeout_ms() ->
    barrel_inference_server_config:generation_idle_ms().

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
    json:encode(#{
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
    }).

openai_tool_call_chunk(S, JsonBin) ->
    {Name, ArgsJson} = parse_tool_call(JsonBin),
    json:encode(#{
        <<"id">> => S#st.req_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => erlang:system_time(second),
        <<"model">> => S#st.requested,
        <<"choices">> => [
            #{
                <<"index">> => 0,
                <<"delta">> => #{
                    <<"role">> => <<"assistant">>,
                    <<"tool_calls">> => [
                        #{
                            <<"index">> => 0,
                            <<"id">> => make_tool_id(),
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
    }).

parse_tool_call(JsonBin) ->
    case json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} ->
            {Name, json:encode(Args)};
        _ ->
            {<<"unknown">>, JsonBin}
    end.

make_tool_id() ->
    iolist_to_binary([<<"call_">>, integer_to_binary(erlang:unique_integer([positive]))]).

is_tool_first_byte(<<>>) -> false;
is_tool_first_byte(<<C, _/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n -> false;
is_tool_first_byte(<<${, _/binary>>) -> true;
is_tool_first_byte(_) -> false.

usage_chunk(#st{include_usage = false}, _Stats) ->
    [];
usage_chunk(S = #st{include_usage = true}, Stats) ->
    Chunk = barrel_inference_server_translate:internal_to_openai_usage_chunk(
        Stats, S#st.req_id, S#st.requested
    ),
    [<<"data: ">>, Chunk, <<"\n\n">>].

%%====================================================================
%% Metrics
%%====================================================================

record_success(S, Stats) ->
    record_metrics(S, 200, Stats),
    barrel_inference_server_metrics:inc_prompt_tokens(
        S#st.model, maps:get(prompt_tokens, Stats, 0)
    ),
    barrel_inference_server_metrics:inc_completion_tokens(
        S#st.model, maps:get(completion_tokens, Stats, 0)
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

emit_raw(Emit, IoData) ->
    case Emit(IoData) of
        ok -> ok;
        {error, _} -> closed
    end.

error_body({context_overflow, Tokens, Ctx}, _Status) ->
    Msg = iolist_to_binary(
        io_lib:format("prompt is too long: ~B tokens > ~B maximum", [Tokens, Ctx])
    ),
    #{<<"error">> => #{
        <<"message">> => Msg,
        <<"type">> => <<"invalid_request_error">>,
        <<"code">> => <<"context_length_exceeded">>
    }};
error_body({error, {decode_failed, _}}, Status) ->
    error_body(decode_failed, Status);
error_body({decode_failed, _}, Status) ->
    error_body(decode_failed, Status);
error_body(decode_failed, _Status) ->
    #{<<"error">> => #{
        <<"message">> =>
            <<"the model was overloaded and could not process this request; please retry">>,
        <<"type">> => <<"server_error">>,
        <<"code">> => <<"server_overloaded">>
    }};
error_body(Reason, Status) ->
    #{<<"error">> => #{
        <<"message">> => to_bin(Reason),
        <<"type">> => error_type(Status),
        <<"code">> => to_bin(Reason)
    }}.

error_type(400) -> <<"invalid_request_error">>;
error_type(404) -> <<"invalid_request_error">>;
error_type(413) -> <<"invalid_request_error">>;
error_type(429) -> <<"rate_limit_error">>;
error_type(_) -> <<"server_error">>.

http_status(prefill_timeout) -> 504;
http_status(generation_idle_timeout) -> 504;
http_status(total_timeout) -> 504;
http_status({error, {decode_failed, _}}) -> 503;
http_status({decode_failed, _}) -> 503;
http_status(_) -> 500.

sse_headers() ->
    [
        {<<"content-type">>, <<"text/event-stream">>},
        {<<"cache-control">>, <<"no-cache">>},
        {<<"x-accel-buffering">>, <<"no">>}
    ].

decode(Body) ->
    try
        case json:decode(Body) of
            M when is_map(M) -> {ok, M};
            _ -> error
        end
    catch
        _:_ -> error
    end.

model_crashed_from(_) -> model_crashed.

stream_idle_timeout() ->
    application:get_env(barrel_inference_server, idle_timeout_ms, 1800000).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

mono_ms() -> erlang:monotonic_time(millisecond).
