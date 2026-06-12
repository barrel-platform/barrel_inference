%%% Livery-side handler for /v1/responses (OpenAI Responses API).
%%%
%%% Coexists with `barrel_inference_server_h_responses' during the
%%% cowboy → livery migration. Mirrors the request/response shape
%%% exactly; only the framework call surface differs.

-module(barrel_inference_server_h_responses).

-export([openai/1]).

%% The receive-loop driven state mutates `ref' / `slot' / `pending_exec'
%% through pipeline messages dialyzer can't trace through.
-dialyzer(
    {nowarn_function, [
        cleanup/1,
        keepalive_release/1,
        maybe_end_session/1,
        record_session_committed/2,
        release_slot/1,
        drive_stream/3,
        drive_buffered/2
    ]}
).

-include("barrel_inference_server.hrl").

-record(st, {
    req_id :: binary(),
    model :: binary(),
    requested :: binary(),
    api :: openai,
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
    started_text_part = false :: boolean(),
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    received_done = false :: boolean(),
    session_id = undefined :: undefined | binary(),
    conv = [] :: [map()],
    response_id :: binary() | undefined,
    msg_id :: binary() | undefined,
    out_index = 0 :: non_neg_integer(),
    content_index = 0 :: non_neg_integer(),
    fc_items = [] :: [map()],
    chat_params_ref = undefined ::
        undefined | barrel_inference_nif:chat_params_ref(),
    captured_calls = [] ::
        [#{id := binary(), name := binary(), input := map(), full_bin := binary()}],
    server_tools = #{} ::
        #{binary() => barrel_inference_server_tool_executor:spec()},
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
    created_sent = false :: boolean(),
    prompt_token_ids = [] :: [non_neg_integer()]
}).

%%====================================================================
%% Entry point
%%====================================================================

openai(Req) ->
    case livery_req:method(Req) of
        <<"POST">> ->
            handle_post(Req);
        _ ->
            livery_resp:json(405, json:encode(error_body(method_not_allowed, 405)))
    end.

handle_post(Req) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Body, Req1} ->
            fast_phase(Body, Req1);
        {too_large, _Req1} ->
            livery_resp:json(
                413, json:encode(error_body(request_too_large, 413))
            )
    end.

fast_phase(Body, Req) ->
    case decode(Body) of
        {ok, Map} ->
            translate(Map, Req);
        error ->
            livery_resp:json(400, json:encode(error_body(invalid_json, 400)))
    end.

translate(Map, Req) ->
    case barrel_inference_server_translate:openai_responses_to_internal(Map) of
        {ok, R0} ->
            R1 = expand_previous_response(Map, R0),
            R2 = R1#barrel_inference_request{
                session_id = barrel_inference_server_session:derive(Req, R1)
            },
            start_inference(R2);
        {error, Reason} ->
            livery_resp:json(400, json:encode(error_body(Reason, 400)))
    end.

expand_previous_response(Map, R) ->
    case maps:get(<<"previous_response_id">>, Map, undefined) of
        Id when is_binary(Id), Id =/= <<>> ->
            case barrel_inference_server_response_store:get(Id) of
                {ok, {_Model, Prior}} ->
                    R#barrel_inference_request{
                        messages = Prior ++ R#barrel_inference_request.messages
                    };
                not_found ->
                    logger:notice(#{
                        event => responses_previous_response_id_miss,
                        previous_response_id => Id
                    }),
                    R
            end;
        _ ->
            R
    end.

start_inference(R0) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    case R1#barrel_inference_request.stream of
        true ->
            livery_resp:stream(
                200,
                sse_headers(),
                fun(Emit) -> drive_stream(R1, Requested, Emit) end
            );
        false ->
            drive_buffered(R1, Requested)
    end.

drive_stream(R, Requested, Emit) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(R, Requested, Worker, Mon, true),
    State1 = arm_total_timer(State),
    _ =
        try
            stream_loop(State1, Emit)
        after
            cleanup(State1)
        end,
    ok.

drive_buffered(R, Requested) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(R, Requested, Worker, Mon, false),
    State1 = arm_total_timer(State),
    try
        buffered_loop(State1)
    after
        cleanup(State1)
    end.

init_state(R, Requested, Worker, Mon, Stream) ->
    barrel_inference_server_metrics:inc_active_streams(
        R#barrel_inference_request.model_id
    ),
    #st{
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = Requested,
        api = openai,
        stream = Stream,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        started_mono = mono_ms(),
        out_tokens = 0,
        buf_text = [],
        mode = text,
        grammar_set = grammar_active(R),
        session_id = R#barrel_inference_request.session_id,
        conv = R#barrel_inference_request.messages,
        response_id = barrel_inference_server_translate:make_id(<<"resp_">>),
        msg_id = barrel_inference_server_translate:make_id(<<"msg_">>),
        server_tools = R#barrel_inference_request.server_tools,
        max_tool_iter = barrel_inference_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#barrel_inference_request.messages
    }.

grammar_active(#barrel_inference_request{tools = undefined}) -> false;
grammar_active(#barrel_inference_request{tools = []}) -> false;
grammar_active(#barrel_inference_request{tool_choice = none}) -> false;
grammar_active(_) -> true.

%%====================================================================
%% Streaming receive loop
%%====================================================================

stream_loop(S, Emit) ->
    receive
        Msg -> dispatch_stream(Msg, S, Emit)
    after stream_idle_timeout() -> S
    end.

dispatch_stream({pipeline, _} = M, S, Emit) ->
    on_pipeline_stream(M, S, Emit);
dispatch_stream({pipeline, _, _} = M, S, Emit) ->
    on_pipeline_stream(M, S, Emit);
dispatch_stream({pipeline, _, _, _} = M, S, Emit) ->
    on_pipeline_stream(M, S, Emit);
dispatch_stream({barrel_inference_token, Ref, Tok}, S, Emit) ->
    on_stream_token(S, Ref, Tok, Emit);
dispatch_stream({barrel_inference_reasoning_token, _Ref, _Tok}, S, Emit) ->
    stream_loop(S, Emit);
dispatch_stream({barrel_inference_done, Ref, Stats}, S, Emit) ->
    on_stream_done(S, Ref, Stats, Emit);
dispatch_stream({barrel_inference_error, Ref, Reason}, S, Emit) ->
    on_stream_engine_error(S, Ref, Reason, Emit);
dispatch_stream({tool_exec_batch_result, BR, Results}, S, Emit) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results(Results, S, Emit, true);
dispatch_stream({exec_timeout, BR}, S, Emit) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
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
        ok -> stream_loop(S, Emit);
        closed -> S
    end;
on_pipeline_stream({pipeline, loaded}, S = #st{keepalive_begun = true}, Emit) ->
    stream_loop(S#st{phase = waiting_template}, Emit);
on_pipeline_stream({pipeline, loaded}, S, Emit) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    stream_loop(S#st{phase = waiting_template, keepalive_begun = true}, Emit);
on_pipeline_stream({pipeline, templated, Tokens, ParamsRef}, S, Emit) ->
    stream_loop(
        S#st{
            phase = waiting_queue,
            prompt_token_ids = Tokens,
            chat_params_ref = ParamsRef
        },
        Emit
    );
on_pipeline_stream({pipeline, queued}, S, Emit) ->
    stream_loop(S#st{phase = waiting_admit}, Emit);
on_pipeline_stream({pipeline, admitted, Ref, Slot}, S, Emit) ->
    S1 = monitor_engine(
        arm_prefill_timer(S#st{phase = running, ref = Ref, slot = Slot})
    ),
    S2 = emit_response_created(S1, Emit),
    S3 = emit_message_added(S2, Emit),
    S4 = emit_content_added(S3, Emit),
    stream_loop(S4, Emit);
on_pipeline_stream({pipeline, error, Status, Reason}, S, Emit) ->
    record_metrics(S, Status),
    Payload = barrel_inference_server_translate:internal_to_responses_failed(
        S#st.response_id,
        S#st.requested,
        error_code(Reason),
        error_message(Reason)
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.failed">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S.

on_stream_token(S0, Ref, Tok, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    case handle_token_stream(Tok, S) of
        {emit, Frame, S1} ->
            case emit_raw(Emit, Frame) of
                ok -> stream_loop(rearm_idle(S1), Emit);
                closed -> S1
            end;
        {buffer, S1} ->
            stream_loop(rearm_idle(S1), Emit)
    end.

handle_token_stream(Tok, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    case is_tool_first_byte(Tok) of
        true ->
            {buffer,
                first_token(S#st{
                    mode = tool_buffer, buf_text = [Tok], out_tokens = 1
                })};
        false ->
            stream_text_frame(Tok, first_token(S))
    end;
handle_token_stream(Tok, S = #st{mode = tool_buffer}) ->
    {buffer, S#st{
        buf_text = [S#st.buf_text, Tok],
        out_tokens = S#st.out_tokens + 1
    }};
handle_token_stream(Tok, S = #st{out_tokens = 0}) ->
    stream_text_frame(Tok, first_token(S));
handle_token_stream(Tok, S) ->
    stream_text_frame(Tok, S).

stream_text_frame(Tok, S) ->
    Payload = barrel_inference_server_translate:internal_to_responses_text_delta(
        S#st.out_index, S#st.content_index, Tok
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.output_text.delta">>, Payload
    ),
    {emit, Frame, S#st{
        buf_text = [S#st.buf_text, Tok],
        out_tokens = S#st.out_tokens + 1
    }}.

on_stream_done(S0, Ref, Stats, Emit) ->
    S = learn_ref(S0, Ref, Emit),
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
        [] ->
            finish_with_function_calls_stream(
                S#st{received_done = true}, ClientCalls, Emit
            );
        _ ->
            begin_server_tools_stream(ServerCalls, S, Emit)
    end.

maybe_legacy_tool_stream(S = #st{mode = tool_buffer}, Emit) ->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    case maps:find(Name, S#st.server_tools) of
        {ok, _} ->
            Call = #{
                id => barrel_inference_server_translate:make_id(<<"fc_">>),
                name => Name,
                input => Input,
                full_bin => Json
            },
            begin_server_tools_stream([Call], S, Emit);
        error ->
            finish_stream_ok(S#st{received_done = true}, S#st.agg_stats, Emit)
    end;
maybe_legacy_tool_stream(S, Emit) ->
    finish_stream_ok(S#st{received_done = true}, S#st.agg_stats, Emit).

finish_stream_ok(S0 = #st{mode = text}, Stats, Emit) ->
    S1 = close_open_message_stream(S0, Emit),
    Items = collect_output_items(S1, iolist_to_binary(S0#st.buf_text)),
    CompletedPayload = barrel_inference_server_translate:internal_to_responses_completed(
        S1#st.response_id, S1#st.msg_id, Items, Stats, S1#st.requested
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.completed">>, CompletedPayload
    ),
    _ = emit_raw(Emit, Frame),
    record_success(S1, Stats),
    store_response(S1, Items),
    S1;
finish_stream_ok(S0 = #st{mode = tool_buffer}, Stats0, Emit) ->
    Json = iolist_to_binary(S0#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    FcId = barrel_inference_server_translate:make_id(<<"fc_">>),
    CallId = barrel_inference_server_translate:make_id(<<"call_">>),
    S1 = close_open_message_stream(S0, Emit),
    OutIdx = S1#st.out_index,
    ArgsBin = args_bin(Input),
    Frames = function_call_frames(OutIdx, FcId, CallId, Name, ArgsBin),
    _ = emit_raw(Emit, Frames),
    Stats = maps:put(finish_reason, tool_call, Stats0),
    Items = S1#st.fc_items ++ [fc_item_map(FcId, CallId, Name, ArgsBin)],
    CompletedPayload = barrel_inference_server_translate:internal_to_responses_completed(
        S1#st.response_id, S1#st.msg_id, Items, Stats, S1#st.requested
    ),
    DoneFrame = barrel_inference_server_translate:responses_event(
        <<"response.completed">>, CompletedPayload
    ),
    _ = emit_raw(Emit, DoneFrame),
    record_success(S1, Stats),
    store_response(S1, Items),
    S1#st{out_index = OutIdx + 1}.

finish_with_function_calls_stream(S0, Calls, Emit) ->
    S1 = close_open_message_stream(S0, Emit),
    {FcItems, S2} = lists:foldl(
        fun(Call, {Acc, Sx}) ->
            {Item, Sx2} = emit_function_item(Sx, Emit, Call),
            {[Item | Acc], Sx2}
        end,
        {[], S1},
        Calls
    ),
    Stats = maps:put(finish_reason, tool_call, S2#st.agg_stats),
    finish_stream_ok(
        S2#st{fc_items = S2#st.fc_items ++ lists:reverse(FcItems), mode = text},
        Stats,
        Emit
    ).

emit_function_item(S, Emit, #{id := FcId, name := Name, input := Input}) ->
    CallId = barrel_inference_server_translate:make_id(<<"call_">>),
    OutIdx = S#st.out_index,
    ArgsBin = iolist_to_binary(json:encode(Input)),
    Frames = function_call_frames(OutIdx, FcId, CallId, Name, ArgsBin),
    _ = emit_raw(Emit, Frames),
    {fc_item_map(FcId, CallId, Name, ArgsBin), S#st{out_index = OutIdx + 1}}.

function_call_frames(OutIdx, FcId, CallId, Name, ArgsBin) ->
    AddedPayload = barrel_inference_server_translate:internal_to_responses_function_call_added(
        OutIdx, FcId, CallId, Name
    ),
    DeltaPayload = barrel_inference_server_translate:internal_to_responses_function_args_delta(
        OutIdx, ArgsBin
    ),
    DonePayload = barrel_inference_server_translate:internal_to_responses_function_args_done(
        OutIdx, ArgsBin
    ),
    ItemDonePayload =
        (barrel_inference_server_translate:internal_to_responses_function_call_done(
            OutIdx, FcId, CallId, Name
        ))#{
            <<"item">> => fc_item_map(FcId, CallId, Name, ArgsBin)
        },
    [
        barrel_inference_server_translate:responses_event(
            <<"response.output_item.added">>, AddedPayload
        ),
        barrel_inference_server_translate:responses_event(
            <<"response.function_call_arguments.delta">>, DeltaPayload
        ),
        barrel_inference_server_translate:responses_event(
            <<"response.function_call_arguments.done">>, DonePayload
        ),
        barrel_inference_server_translate:responses_event(
            <<"response.output_item.done">>, ItemDonePayload
        )
    ].

fc_item_map(FcId, CallId, Name, ArgsBin) ->
    #{
        <<"type">> => <<"function_call">>,
        <<"id">> => FcId,
        <<"call_id">> => CallId,
        <<"name">> => Name,
        <<"arguments">> => ArgsBin,
        <<"status">> => <<"completed">>
    }.

close_open_message_stream(S = #st{started_text_part = true}, Emit) ->
    Text = iolist_to_binary(S#st.buf_text),
    TextDone = barrel_inference_server_translate:internal_to_responses_text_done(
        S#st.out_index, S#st.content_index, Text
    ),
    ContentDone = barrel_inference_server_translate:internal_to_responses_content_done(
        S#st.out_index, S#st.content_index, Text
    ),
    MsgDone = barrel_inference_server_translate:internal_to_responses_message_done(
        S#st.out_index, S#st.msg_id, Text
    ),
    Frames = [
        barrel_inference_server_translate:responses_event(
            <<"response.output_text.done">>, TextDone
        ),
        barrel_inference_server_translate:responses_event(
            <<"response.content_part.done">>, ContentDone
        ),
        barrel_inference_server_translate:responses_event(
            <<"response.output_item.done">>, MsgDone
        )
    ],
    _ = emit_raw(Emit, Frames),
    S#st{
        started_text_part = false,
        out_index = S#st.out_index + 1,
        buf_text = []
    };
close_open_message_stream(S, _Emit) ->
    S.

collect_output_items(S, <<>>) ->
    S#st.fc_items;
collect_output_items(S, Text) ->
    Msg = #{
        <<"type">> => <<"message">>,
        <<"id">> => S#st.msg_id,
        <<"role">> => <<"assistant">>,
        <<"status">> => <<"completed">>,
        <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text}]
    },
    case S#st.fc_items of
        [] -> [Msg];
        _ -> [Msg | S#st.fc_items]
    end.

emit_response_created(S = #st{created_sent = true}, _Emit) ->
    S;
emit_response_created(S, Emit) ->
    Payload = barrel_inference_server_translate:internal_to_responses_partial(
        S#st.response_id, S#st.requested
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.created">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S#st{created_sent = true}.

emit_message_added(S, Emit) ->
    Payload = barrel_inference_server_translate:internal_to_responses_message_added(
        S#st.out_index, S#st.msg_id
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.output_item.added">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S.

emit_content_added(S, Emit) ->
    Payload = barrel_inference_server_translate:internal_to_responses_content_added(
        S#st.out_index, S#st.content_index
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.content_part.added">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S#st{started_text_part = true}.

finish_stream_err(S, Reason, Emit) ->
    Payload = barrel_inference_server_translate:internal_to_responses_failed(
        S#st.response_id,
        S#st.requested,
        error_code(Reason),
        error_message(Reason)
    ),
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.failed">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    record_error(S, Reason),
    S.

on_stream_engine_error(S0, Ref, Reason, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    finish_stream_err(demonitor_engine(S#st{received_done = true}), Reason, Emit).

on_total_timeout(S = #st{ref = Ref}, Emit) when is_reference(Ref) ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, total_timeout, Emit);
on_total_timeout(S, Emit) ->
    finish_stream_err(S, total_timeout, Emit).

on_tool_results(Outcome, S0, Emit, true) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Results = normalise_results(Calls, Outcome),
    S1 = lists:foldl(
        fun(#{call_id := CallId, name := Name, result := R}, Sx) ->
            emit_server_tool_done(Sx, Emit, CallId, Name, result_json(R))
        end,
        S,
        Results
    ),
    Iter = S1#st.tool_iter + 1,
    case Iter >= S1#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S1#st.agg_stats),
            finish_stream_ok(
                S1#st{received_done = true, tool_iter = Iter, mode = text},
                Stats,
                Emit
            );
        false ->
            stream_loop(restart_round(Results, S1), Emit)
    end.

restart_round(Results, S) ->
    NewMessages = S#st.loop_messages ++ tool_round_messages(Results),
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

begin_server_tools_stream(ServerCalls, S0, Emit) ->
    S1 = close_open_message_stream(S0, Emit),
    {Batch, S2} = lists:foldl(
        fun(#{name := Name, input := Input, full_bin := FullBin}, {Acc, Sx}) ->
            CallId = barrel_inference_server_translate:make_id(<<"call_">>),
            Sx2 = emit_server_tool_call(Sx, Emit, CallId, Name),
            Call = #{
                call_id => CallId,
                spec => maps:get(Name, Sx2#st.server_tools),
                name => Name,
                args => Input,
                full_bin => FullBin
            },
            {[Call | Acc], Sx2}
        end,
        {[], S1},
        ServerCalls
    ),
    BatchList = lists:reverse(Batch),
    Ctx = #{
        model => S2#st.model,
        request_id => S2#st.req_id,
        session_id => S2#st.session_id
    },
    {_Pid, Mon, BatchRef} =
        barrel_inference_server_tool_batch:spawn_batch(BatchList, Ctx),
    TRef = erlang:send_after(exec_timeout_ms(), self(), {exec_timeout, BatchRef}),
    Pending = #{batch_ref => BatchRef, calls => BatchList},
    cancel_timer(S2#st.idle_tref),
    stream_loop(
        S2#st{
            pending_exec = Pending,
            exec_mon = Mon,
            exec_tref = TRef,
            idle_tref = undefined,
            captured_calls = []
        },
        Emit
    ).

emit_server_tool_call(S, Emit, CallId, Name) ->
    OutIdx = S#st.out_index,
    Payload = #{
        <<"output_index">> => OutIdx,
        <<"item">> => server_tool_item(CallId, Name, <<"in_progress">>)
    },
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.output_item.added">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S.

emit_server_tool_done(S, Emit, CallId, Name, _ResultJson) ->
    OutIdx = S#st.out_index,
    Payload = #{
        <<"output_index">> => OutIdx,
        <<"item">> => server_tool_item(CallId, Name, <<"completed">>)
    },
    Frame = barrel_inference_server_translate:responses_event(
        <<"response.output_item.done">>, Payload
    ),
    _ = emit_raw(Emit, Frame),
    S#st{out_index = OutIdx + 1}.

server_tool_item(CallId, Name, Status) ->
    #{
        <<"type">> => <<"web_search_call">>,
        <<"id">> => CallId,
        <<"name">> => Name,
        <<"status">> => Status
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

dispatch_buffered({pipeline, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({barrel_inference_token, Ref, Tok}, S) ->
    S1 = learn_ref_b(S, Ref),
    {cont, S2} = handle_token_buffered(Tok, S1),
    buffered_loop(rearm_idle(S2));
dispatch_buffered({barrel_inference_reasoning_token, _Ref, _Tok}, S) ->
    buffered_loop(S);
dispatch_buffered({barrel_inference_done, Ref, Stats}, S) ->
    on_done_buffered(learn_ref_b(S, Ref), Stats);
dispatch_buffered({barrel_inference_error, _Ref, Reason}, S) ->
    record_error(S, Reason),
    finish_err_buffered(Reason);
dispatch_buffered({tool_exec_batch_result, BR, Results}, S) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results_buffered(Results, S);
dispatch_buffered({exec_timeout, BR}, S) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
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

on_pipeline_buffered({pipeline, loading, _M}, S) ->
    buffered_loop(S);
on_pipeline_buffered({pipeline, loaded}, S = #st{keepalive_begun = true}) ->
    buffered_loop(S#st{phase = waiting_template});
on_pipeline_buffered({pipeline, loaded}, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    buffered_loop(S#st{phase = waiting_template, keepalive_begun = true});
on_pipeline_buffered({pipeline, templated, Tokens, ParamsRef}, S) ->
    buffered_loop(S#st{
        phase = waiting_queue,
        prompt_token_ids = Tokens,
        chat_params_ref = ParamsRef
    });
on_pipeline_buffered({pipeline, queued}, S) ->
    buffered_loop(S#st{phase = waiting_admit});
on_pipeline_buffered({pipeline, admitted, Ref, Slot}, S) ->
    S1 = monitor_engine(
        arm_prefill_timer(S#st{phase = running, ref = Ref, slot = Slot})
    ),
    buffered_loop(S1);
on_pipeline_buffered({pipeline, error, Status, Reason}, _S) ->
    livery_resp:json(Status, json:encode(error_body(Reason, Status))).

handle_token_buffered(Tok, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    case is_tool_first_byte(Tok) of
        true ->
            {cont,
                first_token(S#st{
                    mode = tool_buffer, buf_text = [Tok], out_tokens = 1
                })};
        false ->
            {cont,
                first_token(S#st{
                    buf_text = [S#st.buf_text, Tok], out_tokens = 1
                })}
    end;
handle_token_buffered(Tok, S = #st{out_tokens = 0}) ->
    {cont,
        first_token(S#st{
            buf_text = [S#st.buf_text, Tok], out_tokens = 1
        })};
handle_token_buffered(Tok, S) ->
    {cont, S#st{
        buf_text = [S#st.buf_text, Tok],
        out_tokens = S#st.out_tokens + 1
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
        [] ->
            finish_with_function_calls_buffered(
                S#st{received_done = true}, ClientCalls
            );
        _ ->
            begin_server_tools_buffered(ServerCalls, S)
    end.

maybe_legacy_tool_buffered(S = #st{mode = tool_buffer}) ->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    case maps:find(Name, S#st.server_tools) of
        {ok, _} ->
            Call = #{
                id => barrel_inference_server_translate:make_id(<<"fc_">>),
                name => Name,
                input => Input,
                full_bin => Json
            },
            begin_server_tools_buffered([Call], S);
        error ->
            finish_ok_buffered(S#st{received_done = true}, S#st.agg_stats)
    end;
maybe_legacy_tool_buffered(S) ->
    finish_ok_buffered(S#st{received_done = true}, S#st.agg_stats).

finish_ok_buffered(S, Stats0) ->
    Text = iolist_to_binary(S#st.buf_text),
    {Items, Stats} = nonstream_items(S, Text, Stats0),
    Body = barrel_inference_server_translate:internal_to_responses_object(
        S#st.response_id, S#st.msg_id, Items, Stats, S#st.requested
    ),
    record_success(S, Stats),
    store_response(S, Items),
    livery_resp:json(200, json:encode(Body)).

finish_with_function_calls_buffered(S, Calls) ->
    FcItems = [
        fc_item_map(
            Id,
            barrel_inference_server_translate:make_id(<<"call_">>),
            Name,
            iolist_to_binary(json:encode(Input))
        )
     || #{id := Id, name := Name, input := Input} <- Calls
    ],
    Stats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    finish_ok_buffered(
        S#st{fc_items = S#st.fc_items ++ FcItems, mode = text}, Stats
    ).

finish_err_buffered(Reason) ->
    Status = http_status(Reason),
    livery_resp:json(Status, json:encode(error_body(Reason, Status))).

begin_server_tools_buffered(ServerCalls, S) ->
    Batch = [
        #{
            call_id => barrel_inference_server_translate:make_id(<<"call_">>),
            spec => maps:get(Name, S#st.server_tools),
            name => Name,
            args => Input,
            full_bin => FullBin
        }
     || #{name := Name, input := Input, full_bin := FullBin} <- ServerCalls
    ],
    Ctx = #{
        model => S#st.model,
        request_id => S#st.req_id,
        session_id => S#st.session_id
    },
    {_Pid, Mon, BatchRef} =
        barrel_inference_server_tool_batch:spawn_batch(Batch, Ctx),
    TRef = erlang:send_after(exec_timeout_ms(), self(), {exec_timeout, BatchRef}),
    Pending = #{batch_ref => BatchRef, calls => Batch},
    cancel_timer(S#st.idle_tref),
    buffered_loop(S#st{
        pending_exec = Pending,
        exec_mon = Mon,
        exec_tref = TRef,
        idle_tref = undefined,
        captured_calls = []
    }).

on_tool_results_buffered(Outcome, S0) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Results = normalise_results(Calls, Outcome),
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_ok_buffered(
                S#st{received_done = true, tool_iter = Iter, mode = text}, Stats
            );
        false ->
            buffered_loop(restart_round(Results, S))
    end.

nonstream_items(S = #st{mode = tool_buffer, fc_items = []}, _Text, Stats0) ->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    FcId = barrel_inference_server_translate:make_id(<<"fc_">>),
    CallId = barrel_inference_server_translate:make_id(<<"call_">>),
    ArgsBin = args_bin(Input),
    FcItem = fc_item_map(FcId, CallId, Name, ArgsBin),
    Stats = maps:put(finish_reason, tool_call, Stats0),
    {[FcItem], Stats};
nonstream_items(#st{fc_items = FcItems}, <<>>, Stats0) when FcItems =/= [] ->
    Stats = maps:put(finish_reason, tool_call, Stats0),
    {FcItems, Stats};
nonstream_items(S = #st{fc_items = FcItems}, Text, Stats0) ->
    Msg = #{
        <<"type">> => <<"message">>,
        <<"id">> => S#st.msg_id,
        <<"role">> => <<"assistant">>,
        <<"status">> => <<"completed">>,
        <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text}]
    },
    case FcItems of
        [] -> {[Msg], Stats0};
        _ -> {[Msg | FcItems], maps:put(finish_reason, tool_call, Stats0)}
    end.

%%====================================================================
%% Shared helpers
%%====================================================================

learn_ref(S = #st{ref = undefined}, Ref, Emit) ->
    S1 = arm_prefill_timer(S#st{phase = running, ref = Ref}),
    S2 = emit_response_created(S1, Emit),
    S3 = emit_message_added(S2, Emit),
    emit_content_added(S3, Emit);
learn_ref(S, _Ref, _Emit) ->
    S.

learn_ref_b(S = #st{ref = undefined}, Ref) ->
    arm_prefill_timer(S#st{phase = running, ref = Ref});
learn_ref_b(S, _Ref) ->
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

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

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
release_slot(#st{model = Model, slot = Slot}) -> barrel_inference_server_queue:release(Model, Slot).

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

keepalive_release(#st{keepalive_begun = false}) ->
    ok;
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
%% Tool helpers
%%====================================================================

cap_parallel(
    #st{loop_request = #barrel_inference_request{parallel_tool_calls = false}},
    Calls
) ->
    lists:sublist(Calls, 1);
cap_parallel(_S, Calls) ->
    Calls.

partition_calls(Calls, ServerTools) ->
    lists:partition(fun(#{name := N}) -> maps:is_key(N, ServerTools) end, Calls).

maybe_autoparser_extract(S = #st{captured_calls = []}) when
    S#st.loop_request =/= undefined
->
    case
        barrel_inference_server_autoparser:maybe_extract(
            S#st.chat_params_ref,
            S#st.loop_request,
            S#st.buf_text,
            openai
        )
    of
        {ok, Calls} ->
            S#st{captured_calls = Calls, buf_text = []};
        none ->
            S
    end;
maybe_autoparser_extract(S) ->
    S.

parse_tool_call_legacy(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} ->
            {Name, json:encode(Args)};
        _ ->
            {<<"unknown">>, JsonBin}
    catch
        _:_ -> {<<"unknown">>, JsonBin}
    end.

normalise_results(_Calls, Results) when is_list(Results) ->
    Results;
normalise_results(Calls, {error, _} = Err) ->
    [C#{result => Err} || C <- Calls].

tool_round_messages(Results) ->
    lists:flatmap(
        fun(#{call_id := CallId, full_bin := FullBin, result := Result}) ->
            ResultJson = result_json(Result),
            [
                #{role => <<"assistant">>, content => FullBin},
                #{
                    role => <<"tool">>,
                    content =>
                        <<"[tool_result id=", CallId/binary, "]: ", ResultJson/binary>>
                }
            ]
        end,
        Results
    ).

result_json({ok, Json}) when is_map(Json) ->
    iolist_to_binary(json:encode(Json));
result_json({ok, Bin}) when is_binary(Bin) ->
    Bin;
result_json({error, Reason}) ->
    iolist_to_binary(json:encode(#{<<"error">> => to_bin(Reason)})).

exec_timeout_ms() ->
    barrel_inference_server_config:generation_idle_ms().

args_bin(Bin) when is_binary(Bin) -> Bin;
args_bin(V) -> iolist_to_binary(json:encode(V)).

is_tool_first_byte(<<>>) ->
    false;
is_tool_first_byte(<<C, _/binary>>) when
    C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n
->
    false;
is_tool_first_byte(<<${, _/binary>>) ->
    true;
is_tool_first_byte(_) ->
    false.

store_response(#st{response_id = undefined}, _Items) ->
    ok;
store_response(S = #st{response_id = ResponseId, model = Model}, Items) ->
    Conv = S#st.conv ++ items_to_messages(Items),
    barrel_inference_server_response_store:put(ResponseId, Model, Conv).

items_to_messages(Items) ->
    [item_to_message(I) || I <- Items].

item_to_message(#{<<"type">> := <<"message">>, <<"content">> := Content}) ->
    #{role => <<"assistant">>, content => output_text(Content)};
item_to_message(#{<<"type">> := <<"function_call">>} = Item) ->
    Name = maps:get(<<"name">>, Item, <<"unknown">>),
    Id = maps:get(<<"id">>, Item, <<>>),
    #{
        role => <<"assistant">>,
        content => <<"[tool_call name=", Name/binary, " id=", Id/binary, "]">>
    }.

output_text([#{<<"type">> := <<"output_text">>, <<"text">> := Text} | _]) when
    is_binary(Text)
->
    Text;
output_text(_) ->
    <<>>.

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
                    barrel_inference_server_metrics:observe_generation_tps(
                        S#st.model, Tps
                    );
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
    Endpoint = <<"/v1/responses">>,
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
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum", [Tokens, Ctx]
        )
    ),
    #{
        <<"error">> => #{
            <<"message">> => Msg,
            <<"type">> => <<"invalid_request_error">>,
            <<"code">> => <<"context_length_exceeded">>
        }
    };
error_body({error, {decode_failed, _}}, Status) ->
    error_body(decode_failed, Status);
error_body({decode_failed, _}, Status) ->
    error_body(decode_failed, Status);
error_body(decode_failed, _Status) ->
    #{
        <<"error">> => #{
            <<"message">> =>
                <<
                    "the model was overloaded and could not process this "
                    "request; please retry"
                >>,
            <<"type">> => <<"server_error">>,
            <<"code">> => <<"server_overloaded">>
        }
    };
error_body(Reason, Status) ->
    #{
        <<"error">> => #{
            <<"message">> => to_bin(Reason),
            <<"type">> => error_type(Status),
            <<"code">> => to_bin(Reason)
        }
    }.

error_message({context_overflow, Tokens, Ctx}) ->
    iolist_to_binary(
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum", [Tokens, Ctx]
        )
    );
error_message({error, {decode_failed, _}}) ->
    <<"the model was overloaded and could not process this request; please retry">>;
error_message({decode_failed, _}) ->
    <<"the model was overloaded and could not process this request; please retry">>;
error_message(Reason) ->
    to_bin(Reason).

error_code({context_overflow, _, _}) -> <<"context_length_exceeded">>;
error_code({error, {decode_failed, _}}) -> <<"server_overloaded">>;
error_code({decode_failed, _}) -> <<"server_overloaded">>;
error_code(Reason) -> to_bin(Reason).

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
    try json:decode(Body) of
        M when is_map(M) -> {ok, M};
        _ -> error
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
