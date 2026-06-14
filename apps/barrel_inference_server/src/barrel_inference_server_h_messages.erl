%%% Livery-side handler for /v1/messages and /v1/messages/count_tokens
%%% (Anthropic Messages API).
%%%
%%% Coexists with `barrel_inference_server_h_messages' during the cowboy
%%% → livery migration. Mirrors the request/response shape exactly;
%%% only the framework call surface differs.

-module(barrel_inference_server_h_messages).

-export([messages/1, count_tokens/1]).

-dialyzer(
    {nowarn_function, [
        cleanup/1,
        keepalive_release/1,
        maybe_end_session/1,
        record_session_committed/2,
        release_slot/1,
        drive_stream_post_admit/2,
        drive_buffered/1,
        resolve_stream/3,
        pre_admit_loop/1
    ]}
).

-include("barrel_inference_server.hrl").

-record(st, {
    req_id :: binary(),
    model :: binary(),
    requested :: binary(),
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
    gen_ping_tref :: reference() | undefined,
    idle_tref :: reference() | undefined,
    total_tref :: reference() | undefined,
    out_tokens :: non_neg_integer(),
    prompt_tokens :: non_neg_integer(),
    buf_text :: iodata(),
    buf_reason :: iodata(),
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    text_block_started :: undefined | non_neg_integer(),
    thinking_block_started :: undefined | non_neg_integer(),
    cache_hints :: list(),
    user_id = undefined :: undefined | binary(),
    session_id = undefined :: undefined | binary(),
    thinking_signature = undefined :: undefined | binary(),
    thinking_display = visible :: visible | omitted,
    received_done = false :: boolean(),
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
    prompt_token_ids = [] :: [non_neg_integer()],
    message_started = false :: boolean(),
    %% Pre-streaming response headers (anthropic-version echo, request-id
    %% mirror, ratelimit). The handler can't set headers on `Req'
    %% directly the way cowboy did; we collect them here for the
    %% streaming path's livery_resp:stream call. Buffered path applies
    %% them via livery_resp:json with_header.
    extra_headers = [] :: [{binary(), binary()}],
    %% anthropic-beta + body.betas merged at request time, kept for the
    %% structured log field but the engine ignores it for now.
    anthropic_betas = [] :: [binary()]
}).

%%====================================================================
%% Entry points
%%====================================================================

messages(Req) ->
    handle(Req, messages).

count_tokens(Req) ->
    handle(Req, count_tokens).

handle(Req0, Op) ->
    Version = livery_req:header(<<"anthropic-version">>, Req0, <<"2023-06-01">>),
    case check_api_key(Req0) of
        ok ->
            case livery_req:method(Req0) of
                <<"POST">> ->
                    handle_post(Req0, Op, Version);
                _ ->
                    livery_resp:empty(405)
            end;
        unauthorized ->
            anthropic_json_reply(401, authentication_error, Req0, version_headers(Version))
    end.

check_api_key(Req) ->
    case barrel_inference_server_config:anthropic_api_keys() of
        [] ->
            ok;
        Allowed ->
            case livery_req:header(<<"x-api-key">>, Req, undefined) of
                undefined ->
                    unauthorized;
                Key ->
                    case lists:member(Key, Allowed) of
                        true -> ok;
                        false -> unauthorized
                    end
            end
    end.

handle_post(Req0, Op, Version) ->
    case barrel_inference_server_body:read(Req0) of
        {ok, Body, Req1} ->
            fast_phase(Body, Req1, Op, Version);
        {too_large, Req1} ->
            anthropic_json_reply(413, request_too_large, Req1, version_headers(Version))
    end.

fast_phase(Body, Req, Op, Version) ->
    case decode(Body) of
        {ok, Map} ->
            translate(Map, Req, Op, Version);
        error ->
            anthropic_json_reply(400, invalid_json, Req, version_headers(Version))
    end.

translate(Map, Req, Op, Version) ->
    case barrel_inference_server_translate:anthropic_messages_to_internal(Map) of
        {ok, R0} ->
            R1 = R0#barrel_inference_request{
                anthropic_betas = collect_betas(Req, Map)
            },
            R2 = R1#barrel_inference_request{
                session_id = barrel_inference_server_session:derive(Req, R1)
            },
            %% Mirror the middleware-set x-request-id (req_*) on the
            %% literal `request-id' header. Anthropic SDKs read this into
            %% `message._request_id'.
            ReqId = livery_req:req_id(Req),
            ExtraHeaders = base_response_headers(Version, ReqId),
            dispatch(R2, Op, ExtraHeaders, Req);
        {error, Reason} ->
            anthropic_json_reply(400, Reason, Req, version_headers(Version))
    end.

collect_betas(Req, Body) ->
    Header = livery_req:header(<<"anthropic-beta">>, Req, <<>>),
    FromHeader = [
        trim(B)
     || B <- binary:split(Header, <<",">>, [global]), trim(B) =/= <<>>
    ],
    FromBody = barrel_inference_server_translate:parse_anthropic_betas_body(Body),
    lists:usort(FromHeader ++ FromBody).

trim(Bin) when is_binary(Bin) ->
    list_to_binary(string:trim(binary_to_list(Bin))).

dispatch(R, count_tokens, ExtraHeaders, Req) ->
    do_count_tokens(R, ExtraHeaders, Req);
dispatch(R, messages, ExtraHeaders, _Req) ->
    start_inference(R, ExtraHeaders).

do_count_tokens(R0, ExtraHeaders, _LiveryReq) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    Req = #{
        messages => R0#barrel_inference_request.messages,
        system => R0#barrel_inference_request.system,
        tools => R0#barrel_inference_request.tools
    },
    try barrel_inference:apply_chat_template(Real, Req) of
        {ok, Tokens} ->
            Body = json:encode(#{<<"input_tokens">> => length(Tokens)}),
            livery_resp:json(200, ExtraHeaders, Body);
        {error, no_template} ->
            anthropic_json_reply_h(501, no_chat_template, ExtraHeaders);
        {error, not_supported} ->
            anthropic_json_reply_h(501, chat_template_not_supported, ExtraHeaders);
        {error, Reason} ->
            anthropic_json_reply_h(400, Reason, ExtraHeaders)
    catch
        exit:{noproc, {barrel_inference_model, not_found, _}} ->
            anthropic_json_reply_h(503, not_loaded, ExtraHeaders);
        _Class:_Why ->
            anthropic_json_reply_h(500, model_crashed, ExtraHeaders)
    end.

start_inference(R0, ExtraHeaders0) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    ExtraHeaders = ExtraHeaders0 ++ ratelimit_headers(Real),
    case R1#barrel_inference_request.stream of
        true ->
            livery_resp:stream_deferred(
                fun() -> resolve_stream(R1, Requested, ExtraHeaders) end
            );
        false ->
            drive_buffered(make_init(R1, Requested, ExtraHeaders))
    end.

%% Sync pre-admit: emit a real 4xx/5xx status when admission fails
%% before any SSE frame is written; otherwise hand the admitted state
%% off to the streaming producer.
resolve_stream(R, Requested, ExtraHeaders) ->
    State = arm_total_timer(make_init(R, Requested, ExtraHeaders)),
    case pre_admit_loop(State) of
        {admitted, State1} ->
            %% Raw chunked: our Emit calls already produce full SSE
            %% frames (event/data/blank line); `{sse,_}' would
            %% double-wrap them.
            {stream, 200, sse_headers() ++ ExtraHeaders, fun(Emit) ->
                drive_stream_post_admit(State1, Emit)
            end};
        {error, Status0, Reason, State1} ->
            cleanup(State1),
            %% Honour the 503 -> 529 + Retry-After Anthropic remap on
            %% the pre-admit error path the same way the buffered
            %% response path does it via anthropic_json_reply_h.
            {Status, BodyStatus, Headers} = anthropic_overload_remap(Status0, ExtraHeaders),
            Body = json:encode(anthropic_error_body_h(BodyStatus, Reason, Headers)),
            {full, Status, Headers ++ json_headers(), Body}
    end.

make_init(R, Requested, ExtraHeaders) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    init_state(R, Requested, Worker, Mon, ExtraHeaders).

drive_stream_post_admit(State, Emit) ->
    %% In the cowboy-era flow `on_pipeline_stream({pipeline, admitted,
    %% _, _})' was the spot where we first had both the Emit fun and
    %% an admitted state, so it emitted `message_start' and armed the
    %% per-generation ping timer. pre_admit_loop now consumes the
    %% admit message before any Emit exists; the post-admit producer
    %% takes over both responsibilities here.
    State1 = arm_gen_ping(emit_message_start(State, Emit)),
    _ =
        try
            stream_loop(State1, Emit)
        after
            cleanup(State1)
        end,
    ok.

pre_admit_loop(S) ->
    receive
        {pipeline, error, Status, Reason} ->
            {error, Status, Reason, S};
        {pipeline, loading, _M} ->
            pre_admit_loop(S);
        {pipeline, loaded} when S#st.keepalive_begun ->
            pre_admit_loop(S#st{phase = waiting_template});
        {pipeline, loaded} ->
            ok = barrel_inference_server_keepalive:request_begin(S#st.model),
            pre_admit_loop(S#st{phase = waiting_template, keepalive_begun = true});
        {pipeline, templated, Tokens, ParamsRef} ->
            pre_admit_loop(S#st{
                phase = waiting_queue,
                prompt_tokens = length(Tokens),
                prompt_token_ids = Tokens,
                chat_params_ref = ParamsRef
            });
        {pipeline, queued} ->
            pre_admit_loop(S#st{phase = waiting_admit});
        {pipeline, admitted, Ref, Slot} ->
            S1 = monitor_engine(
                arm_prefill(S#st{phase = running, ref = Ref, slot = Slot})
            ),
            {admitted, S1};
        {'DOWN', Mon, process, _Pid, _Reason} when Mon =:= S#st.engine_mon ->
            {error, 500, model_crashed, S#st{engine_mon = undefined}};
        {'DOWN', Mon, process, _Pid, normal} when Mon =:= S#st.worker_mon ->
            pre_admit_loop(S#st{worker = undefined, worker_mon = undefined});
        {'DOWN', Mon, process, _Pid, _Reason} when Mon =:= S#st.worker_mon ->
            {error, 500, pipeline_crashed, S#st{worker = undefined, worker_mon = undefined}};
        _Other ->
            pre_admit_loop(S)
    after pre_admit_timeout() ->
        {error, 504, prefill_timeout, S}
    end.

pre_admit_timeout() ->
    barrel_inference_server_config:prefill_ms().

json_headers() ->
    [{<<"content-type">>, <<"application/json">>}].

drive_buffered(State0) ->
    State = arm_total_timer(State0),
    try
        buffered_loop(State)
    after
        cleanup(State)
    end.

init_state(R, Requested, Worker, Mon, ExtraHeaders) ->
    barrel_inference_server_metrics:inc_active_streams(
        R#barrel_inference_request.model_id
    ),
    #st{
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = Requested,
        stream = R#barrel_inference_request.stream,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        started_mono = mono_ms(),
        out_tokens = 0,
        prompt_tokens = 0,
        buf_text = [],
        buf_reason = [],
        mode = text,
        grammar_set = grammar_active(R),
        cache_hints = R#barrel_inference_request.cache_hints,
        thinking_display = R#barrel_inference_request.thinking_display,
        user_id = R#barrel_inference_request.user_id,
        session_id = R#barrel_inference_request.session_id,
        server_tools = R#barrel_inference_request.server_tools,
        max_tool_iter = barrel_inference_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#barrel_inference_request.messages,
        extra_headers = ExtraHeaders,
        anthropic_betas = R#barrel_inference_request.anthropic_betas
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
dispatch_stream({barrel_inference_token, Ref, {thinking_delta, Bin}}, S, Emit) ->
    on_thinking_token(S, Ref, Bin, Emit);
dispatch_stream({barrel_inference_token, Ref, Tok}, S, Emit) when is_binary(Tok) ->
    on_text_token(S, Ref, Tok, Emit);
dispatch_stream({barrel_inference_reasoning_token, Ref, Tok}, S, Emit) ->
    on_thinking_token(S, Ref, Tok, Emit);
dispatch_stream({barrel_inference_thinking_end, Ref, Sig}, S, Emit) ->
    on_thinking_end(S, Ref, Sig, Emit);
dispatch_stream({barrel_inference_done, Ref, Stats}, S, Emit) ->
    on_done_stream(S, Ref, Stats, Emit);
dispatch_stream({barrel_inference_error, Ref, Reason}, S, Emit) ->
    on_engine_error_stream(S, Ref, Reason, Emit);
dispatch_stream({tool_exec_batch_result, BR, Results}, S, Emit) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results_stream(Results, S, Emit);
dispatch_stream({exec_timeout, BR}, S, Emit) when
    is_map(S#st.pending_exec),
    map_get(batch_ref, S#st.pending_exec) =:= BR
->
    on_tool_results_stream({error, executor_timeout}, S, Emit);
dispatch_stream({'DOWN', Mon, process, _Pid, Reason}, S, Emit) when
    Mon =:= S#st.engine_mon
->
    finish_stream_err(S#st{engine_mon = undefined}, model_crashed_from(Reason), Emit);
dispatch_stream({'DOWN', Mon, process, _Pid, normal}, S, Emit) when
    Mon =:= S#st.worker_mon
->
    stream_loop(S#st{worker = undefined, worker_mon = undefined}, Emit);
dispatch_stream({'DOWN', Mon, process, _Pid, _R}, S, Emit) when
    Mon =:= S#st.exec_mon
->
    stream_loop(S#st{exec_mon = undefined}, Emit);
dispatch_stream({prefill_timeout, Ref}, S, Emit) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, prefill_timeout, Emit);
dispatch_stream({idle_timeout, Ref}, S, Emit) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, generation_idle_timeout, Emit);
dispatch_stream({gen_ping, Ref}, S, Emit) when S#st.ref =:= Ref ->
    _ = emit_raw(Emit, anthropic_ping_frame()),
    stream_loop(arm_gen_ping(S), Emit);
dispatch_stream(total_request_timeout, S, Emit) ->
    on_total_timeout(S, Emit);
dispatch_stream(_Other, S, Emit) ->
    stream_loop(S, Emit).

on_pipeline_stream({pipeline, loading, _M}, S, Emit) ->
    _ = emit_raw(Emit, anthropic_ping_frame()),
    stream_loop(S, Emit);
on_pipeline_stream({pipeline, loaded}, S = #st{keepalive_begun = true}, Emit) ->
    stream_loop(S#st{phase = waiting_template}, Emit);
on_pipeline_stream({pipeline, loaded}, S, Emit) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    stream_loop(S#st{phase = waiting_template, keepalive_begun = true}, Emit);
on_pipeline_stream({pipeline, templated, Tokens, ParamsRef}, S, Emit) ->
    stream_loop(
        S#st{
            phase = waiting_queue,
            prompt_tokens = length(Tokens),
            prompt_token_ids = Tokens,
            chat_params_ref = ParamsRef
        },
        Emit
    );
on_pipeline_stream({pipeline, queued}, S, Emit) ->
    stream_loop(S#st{phase = waiting_admit}, Emit);
on_pipeline_stream({pipeline, admitted, Ref, Slot}, S, Emit) ->
    S1 = monitor_engine(
        arm_prefill(S#st{phase = running, ref = Ref, slot = Slot})
    ),
    S2 = emit_message_start(S1, Emit),
    stream_loop(arm_gen_ping(S2), Emit);
on_pipeline_stream({pipeline, error, Status, Reason}, S, Emit) ->
    record_metrics(S, Status),
    Err = anthropic_error_body(Status, Reason, S),
    _ = emit_raw(Emit, anthropic_event_frame(<<"error">>, Err)),
    S.

on_text_token(S0, Ref, Tok, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    handle_text_token(Tok, S, Emit).

handle_text_token(Tok, S = #st{out_tokens = 0, mode = text, grammar_set = true}, Emit) ->
    case is_tool_first_byte(Tok) of
        true ->
            stream_loop(
                rearm_idle(
                    first_token(S#st{
                        mode = tool_buffer,
                        buf_text = [Tok],
                        out_tokens = 1
                    })
                ),
                Emit
            );
        false ->
            stream_text_emit(Tok, first_token(S), Emit)
    end;
handle_text_token(Tok, S = #st{mode = tool_buffer}, Emit) ->
    stream_loop(
        rearm_idle(S#st{
            buf_text = [S#st.buf_text, Tok],
            out_tokens = S#st.out_tokens + 1
        }),
        Emit
    );
handle_text_token(Tok, S = #st{mode = text, out_tokens = 0}, Emit) ->
    stream_text_emit(Tok, first_token(S), Emit);
handle_text_token(Tok, S, Emit) ->
    stream_text_emit(Tok, S, Emit).

stream_text_emit(Tok, S, Emit) ->
    S1 = ensure_text_block_started(S, Emit),
    Frame = barrel_inference_server_translate:internal_to_anthropic_event(
        {text_delta, Tok, S1#st.text_block_started},
        #{},
        S1#st.req_id,
        S1#st.requested
    ),
    case emit_raw(Emit, Frame) of
        ok ->
            stream_loop(rearm_idle(S1#st{out_tokens = S1#st.out_tokens + 1}), Emit);
        closed ->
            S1
    end.

on_thinking_token(S0, Ref, _Tok, Emit) when
    is_record(S0, st), S0#st.thinking_display =:= omitted
->
    S = learn_ref(S0, Ref, Emit),
    stream_loop(rearm_idle(S), Emit);
on_thinking_token(S0, Ref, Tok, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    S1 = ensure_thinking_block_started(S, Emit),
    Frame = barrel_inference_server_translate:internal_to_anthropic_event(
        {thinking_delta, Tok, S1#st.thinking_block_started},
        #{},
        S1#st.req_id,
        S1#st.requested
    ),
    case emit_raw(Emit, Frame) of
        ok -> stream_loop(rearm_idle(S1), Emit);
        closed -> S1
    end.

on_thinking_end(S0, Ref, Sig, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    case S#st.thinking_display of
        omitted ->
            stream_loop(rearm_idle(S#st{thinking_signature = Sig}), Emit);
        _ ->
            handle_thinking_end_visible(S, Sig, Emit)
    end.

handle_thinking_end_visible(S = #st{thinking_block_started = Idx}, Sig, Emit) when
    is_integer(Idx)
->
    case Sig of
        <<>> ->
            ok;
        _ ->
            Delta = #{
                <<"type">> => <<"content_block_delta">>,
                <<"index">> => Idx,
                <<"delta">> => #{
                    <<"type">> => <<"signature_delta">>,
                    <<"signature">> => base64:encode(Sig)
                }
            },
            _ = emit_raw(Emit, [
                <<"event: content_block_delta\ndata: ">>,
                json:encode(Delta),
                <<"\n\n">>
            ])
    end,
    S1 = maybe_close_thinking(S, Emit),
    stream_loop(rearm_idle(S1#st{thinking_signature = Sig}), Emit);
handle_thinking_end_visible(S, Sig, Emit) ->
    stream_loop(rearm_idle(S#st{thinking_signature = Sig}), Emit).

on_done_stream(S0, Ref, Stats, Emit) ->
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
            finish_with_tool_uses_stream(
                S#st{received_done = true}, ClientCalls, Emit
            );
        _ ->
            begin_server_tools_stream(ServerCalls, S, Emit)
    end.

maybe_legacy_tool_stream(S = #st{mode = tool_buffer, server_tools = ST}, Emit) when
    map_size(ST) > 0
->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call(Json),
    case maps:find(Name, ST) of
        {ok, _} ->
            Call = #{
                id => make_tool_id(),
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

finish_stream_ok(S0 = #st{mode = text}, Stats0, Emit) ->
    Stats = maybe_set_tool_call_finish_reason(S0, Stats0),
    S1 = close_open_blocks(S0, Emit),
    Delta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(Stats, S1)},
        #{},
        S1#st.req_id,
        S1#st.requested
    ),
    Stop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S1#st.req_id, S1#st.requested
    ),
    _ = emit_raw(Emit, [Delta, Stop]),
    record_success(S1, Stats),
    S1;
finish_stream_ok(S0 = #st{mode = tool_buffer}, Stats0, Emit) ->
    S = maybe_close_thinking(S0, Emit),
    Idx = next_block_index(S),
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call(Json),
    ToolId = make_tool_id(),
    Frames = tool_use_block_frames(S, Idx, ToolId, Name, Input),
    StatsToolCall = maps:put(finish_reason, tool_call, Stats0),
    MsgDelta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(StatsToolCall, S)},
        #{},
        S#st.req_id,
        S#st.requested
    ),
    MsgStop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S#st.req_id, S#st.requested
    ),
    _ = emit_raw(Emit, [Frames, MsgDelta, MsgStop]),
    record_success(S, StatsToolCall),
    S.

finish_with_tool_uses_stream(S0, Calls, Emit) ->
    S = close_open_blocks(S0, Emit),
    Base = next_block_index(S),
    Frames = tool_use_frames(S, Calls, Base),
    StatsTC = maps:put(finish_reason, tool_call, S#st.agg_stats),
    MsgDelta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(StatsTC, S)},
        #{},
        S#st.req_id,
        S#st.requested
    ),
    MsgStop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S#st.req_id, S#st.requested
    ),
    _ = emit_raw(Emit, [Frames, MsgDelta, MsgStop]),
    record_success(S, StatsTC),
    S.

tool_use_block_frames(S, Idx, ToolId, Name, Input) ->
    Start = #{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Idx,
        <<"content_block">> => #{
            <<"type">> => <<"tool_use">>,
            <<"id">> => ToolId,
            <<"name">> => Name,
            <<"input">> => #{}
        }
    },
    DeltaInput = #{
        <<"type">> => <<"content_block_delta">>,
        <<"index">> => Idx,
        <<"delta">> => #{
            <<"type">> => <<"input_json_delta">>,
            <<"partial_json">> => iolist_to_binary(json:encode(Input))
        }
    },
    Stop = barrel_inference_server_translate:internal_to_anthropic_event(
        {content_block_stop, Idx}, #{}, S#st.req_id, S#st.requested
    ),
    [
        <<"event: content_block_start\ndata: ">>,
        json:encode(Start),
        <<"\n\n">>,
        <<"event: content_block_delta\ndata: ">>,
        json:encode(DeltaInput),
        <<"\n\n">>,
        Stop
    ].

tool_use_frames(S, Calls, Base) ->
    {Frames, _} = lists:mapfoldl(
        fun(Call, Idx) -> {tool_use_frame(S, Idx, Call), Idx + 1} end,
        Base,
        Calls
    ),
    Frames.

tool_use_frame(S, Idx, #{id := Id, name := Name, input := Input}) ->
    tool_use_block_frames(S, Idx, Id, Name, Input).

close_open_blocks(S0, Emit) ->
    S1 = maybe_close_thinking(S0, Emit),
    case S1#st.text_block_started of
        undefined ->
            S1;
        TIdx ->
            Stop = barrel_inference_server_translate:internal_to_anthropic_event(
                {content_block_stop, TIdx}, #{}, S1#st.req_id, S1#st.requested
            ),
            _ = emit_raw(Emit, Stop),
            S1#st{text_block_started = undefined}
    end.

emit_message_start(S = #st{message_started = true}, _Emit) ->
    S;
emit_message_start(S, Emit) ->
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_start, S#st.prompt_tokens}, #{}, S#st.req_id, S#st.requested
    ),
    _ = emit_raw(Emit, Iolist),
    S#st{message_started = true}.

ensure_text_block_started(S = #st{text_block_started = I}, _Emit) when
    is_integer(I)
->
    S;
ensure_text_block_started(S0, Emit) ->
    S1 = maybe_close_thinking(S0, Emit),
    Idx = next_block_index(S1),
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {content_block_start_text, Idx}, #{}, S1#st.req_id, S1#st.requested
    ),
    _ = emit_raw(Emit, Iolist),
    S1#st{text_block_started = Idx}.

ensure_thinking_block_started(S = #st{thinking_block_started = I}, _Emit) when
    is_integer(I)
->
    S;
ensure_thinking_block_started(S, Emit) ->
    Idx = next_block_index(S),
    Payload = #{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Idx,
        <<"content_block">> => #{
            <<"type">> => <<"thinking">>, <<"thinking">> => <<>>
        }
    },
    _ = emit_raw(Emit, [
        <<"event: content_block_start\ndata: ">>,
        json:encode(Payload),
        <<"\n\n">>
    ]),
    S#st{thinking_block_started = Idx}.

maybe_close_thinking(S = #st{thinking_block_started = undefined}, _Emit) ->
    S;
maybe_close_thinking(S = #st{thinking_block_started = Idx}, Emit) ->
    Frame = barrel_inference_server_translate:internal_to_anthropic_event(
        {content_block_stop, Idx}, #{}, S#st.req_id, S#st.requested
    ),
    _ = emit_raw(Emit, Frame),
    S#st{thinking_block_started = undefined}.

next_block_index(#st{text_block_started = T, thinking_block_started = K}) ->
    Indices = [I || I <- [T, K], is_integer(I)],
    case Indices of
        [] -> 0;
        _ -> lists:max(Indices) + 1
    end.

attach_cache_hints(Stats, #st{cache_hints = []}) -> Stats;
attach_cache_hints(Stats, #st{cache_hints = Hints}) -> Stats#{cache_hints => Hints}.

maybe_set_tool_call_finish_reason(#st{captured_calls = []}, Stats) ->
    Stats;
maybe_set_tool_call_finish_reason(_, Stats) ->
    maps:put(finish_reason, tool_call, Stats).

finish_stream_err(S, Reason, Emit) ->
    Status = http_status(Reason),
    Err = anthropic_error_body(Status, Reason, S),
    _ = emit_raw(Emit, anthropic_event_frame(<<"error">>, Err)),
    record_error(S, Reason),
    S.

on_engine_error_stream(S0, Ref, Reason, Emit) ->
    S = learn_ref(S0, Ref, Emit),
    finish_stream_err(demonitor_engine(S#st{received_done = true}), Reason, Emit).

on_total_timeout(S = #st{ref = Ref}, Emit) when is_reference(Ref) ->
    barrel_inference:cancel(Ref),
    finish_stream_err(S, total_timeout, Emit);
on_total_timeout(S, Emit) ->
    finish_stream_err(S, total_timeout, Emit).

on_tool_results_stream(Outcome, S0, Emit) ->
    #{calls := Calls} = S0#st.pending_exec,
    S = clear_pending(S0),
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_stream_ok(
                S#st{
                    received_done = true,
                    tool_iter = Iter,
                    mode = text,
                    buf_text = []
                },
                Stats,
                Emit
            );
        false ->
            stream_loop(restart_round(Calls, Outcome, S), Emit)
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

begin_server_tools_stream(ServerCalls, S0, Emit) ->
    S = close_open_blocks(S0, Emit),
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
    {_Pid, Mon, BatchRef} =
        barrel_inference_server_tool_batch:spawn_batch(Batch, Ctx),
    TRef = erlang:send_after(exec_timeout_ms(), self(), {exec_timeout, BatchRef}),
    Pending = #{batch_ref => BatchRef, calls => Batch},
    cancel_timer(S#st.idle_tref),
    stream_loop(
        S#st{
            pending_exec = Pending,
            exec_mon = Mon,
            exec_tref = TRef,
            idle_tref = undefined,
            captured_calls = []
        },
        Emit
    ).

%%====================================================================
%% Buffered (non-stream) receive loop
%%====================================================================

buffered_loop(S) ->
    receive
        Msg -> dispatch_buffered(Msg, S)
    after stream_idle_timeout() ->
        anthropic_json_reply_h(504, idle_timeout, S#st.extra_headers)
    end.

dispatch_buffered({pipeline, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({pipeline, _, _, _} = M, S) ->
    on_pipeline_buffered(M, S);
dispatch_buffered({barrel_inference_token, Ref, {thinking_delta, Bin}}, S) ->
    S1 = learn_ref_b(S, Ref),
    buffered_loop(rearm_idle(S1#st{buf_reason = [S1#st.buf_reason | Bin]}));
dispatch_buffered({barrel_inference_token, Ref, Tok}, S) when is_binary(Tok) ->
    S1 = learn_ref_b(S, Ref),
    {cont, S2} = handle_token_buffered(Tok, S1),
    buffered_loop(rearm_idle(S2));
dispatch_buffered({barrel_inference_reasoning_token, Ref, Tok}, S) ->
    S1 = learn_ref_b(S, Ref),
    buffered_loop(rearm_idle(S1#st{buf_reason = [S1#st.buf_reason | Tok]}));
dispatch_buffered({barrel_inference_thinking_end, _Ref, Sig}, S) ->
    buffered_loop(S#st{thinking_signature = Sig});
dispatch_buffered({barrel_inference_done, Ref, Stats}, S) ->
    on_done_buffered(learn_ref_b(S, Ref), Stats);
dispatch_buffered({barrel_inference_error, _Ref, Reason}, S) ->
    record_error(S, Reason),
    anthropic_json_reply_h(http_status(Reason), Reason, S#st.extra_headers);
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
    anthropic_json_reply_h(504, prefill_timeout, S#st.extra_headers);
dispatch_buffered({idle_timeout, Ref}, S) when S#st.ref =:= Ref ->
    barrel_inference:cancel(Ref),
    anthropic_json_reply_h(504, generation_idle_timeout, S#st.extra_headers);
dispatch_buffered(total_request_timeout, S) ->
    case S#st.ref of
        Ref when is_reference(Ref) -> barrel_inference:cancel(Ref);
        _ -> ok
    end,
    anthropic_json_reply_h(504, total_timeout, S#st.extra_headers);
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
        prompt_tokens = length(Tokens),
        prompt_token_ids = Tokens,
        chat_params_ref = ParamsRef
    });
on_pipeline_buffered({pipeline, queued}, S) ->
    buffered_loop(S#st{phase = waiting_admit});
on_pipeline_buffered({pipeline, admitted, Ref, Slot}, S) ->
    S1 = monitor_engine(
        arm_prefill(S#st{phase = running, ref = Ref, slot = Slot})
    ),
    buffered_loop(S1);
on_pipeline_buffered({pipeline, error, Status, Reason}, S) ->
    record_metrics(S, Status),
    anthropic_json_reply_h(Status, Reason, S#st.extra_headers).

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
            finish_with_tool_uses_buffered(
                S#st{received_done = true}, ClientCalls
            );
        _ ->
            begin_server_tools_buffered(ServerCalls, S)
    end.

maybe_legacy_tool_buffered(S = #st{mode = tool_buffer, server_tools = ST}) when
    map_size(ST) > 0
->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call(Json),
    case maps:find(Name, ST) of
        {ok, _} ->
            Call = #{
                id => make_tool_id(),
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
    {Content, Stats} = nonstream_content(S, Stats0),
    Body = barrel_inference_server_translate:internal_to_anthropic_messages_response(
        Content, attach_cache_hints(Stats, S), S#st.requested
    ),
    record_success(S, Stats),
    livery_resp:json(200, S#st.extra_headers, json:encode(Body)).

finish_with_tool_uses_buffered(S, Calls) ->
    Blocks = [
        #{
            <<"type">> => <<"tool_use">>,
            <<"id">> => Id,
            <<"name">> => N,
            <<"input">> => I
        }
     || #{id := Id, name := N, input := I} <- Calls
    ],
    Stats = maps:put(finish_reason, tool_call, S#st.agg_stats),
    Body = barrel_inference_server_translate:internal_to_anthropic_messages_response(
        Blocks, attach_cache_hints(Stats, S), S#st.requested
    ),
    record_success(S, Stats),
    livery_resp:json(200, S#st.extra_headers, json:encode(Body)).

begin_server_tools_buffered(ServerCalls, S) ->
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
    Iter = S#st.tool_iter + 1,
    case Iter >= S#st.max_tool_iter of
        true ->
            Stats = maps:put(finish_reason, length, S#st.agg_stats),
            finish_ok_buffered(
                S#st{
                    received_done = true,
                    tool_iter = Iter,
                    mode = text,
                    buf_text = []
                },
                Stats
            );
        false ->
            buffered_loop(restart_round(Calls, Outcome, S))
    end.

nonstream_content(#st{mode = tool_buffer, buf_text = Buf}, Stats) ->
    Json = iolist_to_binary(Buf),
    {Name, Input} = parse_tool_call(Json),
    ToolUse = #{
        <<"type">> => <<"tool_use">>,
        <<"id">> => make_tool_id(),
        <<"name">> => Name,
        <<"input">> => Input
    },
    {[ToolUse], maps:put(finish_reason, tool_call, Stats)};
nonstream_content(
    #st{
        mode = text,
        buf_text = TextBuf,
        buf_reason = ReasonBuf,
        thinking_signature = Sig,
        thinking_display = Display
    },
    Stats
) ->
    Text = iolist_to_binary(TextBuf),
    Reason = iolist_to_binary(ReasonBuf),
    TextBlock = #{<<"type">> => <<"text">>, <<"text">> => Text},
    Blocks =
        case {Reason, Display} of
            {<<>>, _} -> [TextBlock];
            {_, omitted} -> [TextBlock];
            {_, visible} -> [thinking_block(Reason, Sig), TextBlock]
        end,
    {Blocks, Stats}.

thinking_block(Text, undefined) ->
    #{<<"type">> => <<"thinking">>, <<"thinking">> => Text};
thinking_block(Text, <<>>) ->
    #{<<"type">> => <<"thinking">>, <<"thinking">> => Text};
thinking_block(Text, Sig) when is_binary(Sig) ->
    #{
        <<"type">> => <<"thinking">>,
        <<"thinking">> => Text,
        <<"signature">> => base64:encode(Sig)
    }.

%%====================================================================
%% Shared
%%====================================================================

learn_ref(S = #st{ref = undefined}, Ref, Emit) ->
    S1 = arm_prefill(S#st{phase = running, ref = Ref}),
    S2 = emit_message_start(S1, Emit),
    arm_gen_ping(S2);
learn_ref(S, _Ref, _Emit) ->
    S.

learn_ref_b(S = #st{ref = undefined}, Ref) ->
    arm_prefill(S#st{phase = running, ref = Ref});
learn_ref_b(S, _Ref) ->
    S.

first_token(S = #st{first_token_at = undefined}) ->
    Now = mono_ms(),
    PrefillSec = (Now - S#st.started_mono) / 1000.0,
    barrel_inference_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    rearm_idle(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

arm_prefill(S = #st{ref = undefined}) ->
    S;
arm_prefill(S = #st{ref = Ref}) ->
    Ms = barrel_inference_server_config:prefill_ms(),
    S#st{prefill_tref = erlang:send_after(Ms, self(), {prefill_timeout, Ref})}.

rearm_idle(S) ->
    cancel_timer(S#st.idle_tref),
    case S#st.ref of
        undefined ->
            S;
        Ref ->
            Ms = barrel_inference_server_config:generation_idle_ms(),
            S#st{idle_tref = erlang:send_after(Ms, self(), {idle_timeout, Ref})}
    end.

arm_gen_ping(S = #st{ref = Ref}) when is_reference(Ref) ->
    cancel_timer(S#st.gen_ping_tref),
    Ms = barrel_inference_server_config:generation_ping_ms(),
    S#st{gen_ping_tref = erlang:send_after(Ms, self(), {gen_ping, Ref})};
arm_gen_ping(S) ->
    S.

arm_total_timer(S) ->
    Ms =
        case barrel_inference_server_config:total_ms() of
            N when is_integer(N), N > 0 -> N;
            _ -> 1800000
        end,
    S#st{total_tref = erlang:send_after(Ms, self(), total_request_timeout)}.

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
    cancel_timer(S#st.gen_ping_tref),
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

maybe_autoparser_extract(S = #st{buf_text = BufText, chat_params_ref = Ref}) when
    S#st.loop_request =/= undefined
->
    case
        barrel_inference_server_autoparser:maybe_extract(
            Ref, S#st.loop_request, BufText, anthropic
        )
    of
        {ok, Calls} ->
            S#st{captured_calls = S#st.captured_calls ++ Calls, buf_text = []};
        none ->
            S
    end;
maybe_autoparser_extract(S) ->
    S.

parse_tool_call(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} -> {Name, Args};
        _ -> {<<"unknown">>, JsonBin}
    catch
        _:_ -> {<<"unknown">>, JsonBin}
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
            content =>
                <<"[tool_result id=", CallId/binary, "]: ", ResultJson/binary>>
        }
    ].

result_json({ok, Json}) when is_map(Json) ->
    iolist_to_binary(json:encode(Json));
result_json({ok, Bin}) when is_binary(Bin) ->
    Bin;
result_json({error, Reason}) ->
    iolist_to_binary(json:encode(#{<<"error">> => to_bin(Reason)})).

exec_timeout_ms() ->
    barrel_inference_server_config:generation_idle_ms().

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

make_tool_id() ->
    iolist_to_binary([
        <<"toolu_">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

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
    ).

record_error(S, _Reason) -> record_metrics(S, 500).

record_metrics(S, Status) -> record_metrics(S, Status, #{}).
record_metrics(S, Status, Stats) ->
    Now = mono_ms(),
    Duration = (Now - S#st.started_mono) / 1000.0,
    barrel_inference_server_metrics:record_request(
        <<"/v1/messages">>,
        S#st.requested,
        integer_to_binary(Status),
        Duration
    ),
    logger:notice(
        maps:merge(
            #{
                event => anthropic_request,
                endpoint => <<"/v1/messages">>,
                model => S#st.requested,
                status => Status,
                duration_ms => round(Duration * 1000),
                request_id => S#st.req_id,
                user_id => S#st.user_id
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

anthropic_ping_frame() ->
    anthropic_event_frame(<<"ping">>, #{<<"type">> => <<"ping">>}).

anthropic_event_frame(EventName, JsonMap) ->
    [
        <<"event: ">>,
        EventName,
        <<"\n">>,
        <<"data: ">>,
        json:encode(JsonMap),
        <<"\n\n">>
    ].

%% Base response headers built at request translate time: anthropic-version
%% echo + request-id mirror (literal "request-id" alongside the
%% x-request-id middleware stamp).
base_response_headers(Version, ReqId) ->
    [
        {<<"anthropic-version">>, Version},
        {<<"request-id">>, ReqId}
    ].

version_headers(Version) ->
    [{<<"anthropic-version">>, Version}].

ratelimit_headers(Model) ->
    #{concurrency := Limit, inflight := Inflight} =
        barrel_inference_server_queue:stats(Model),
    Remaining = max(0, Limit - Inflight),
    Reset = ratelimit_reset(),
    [
        {<<"anthropic-ratelimit-requests-limit">>, integer_to_binary(Limit)},
        {<<"anthropic-ratelimit-requests-remaining">>, integer_to_binary(Remaining)},
        {<<"anthropic-ratelimit-requests-reset">>, Reset}
    ].

ratelimit_reset() ->
    Seconds = barrel_inference_server_config:anthropic_retry_after_seconds(),
    list_to_binary(
        calendar:system_time_to_rfc3339(erlang:system_time(second) + Seconds, [
            {offset, "Z"}
        ])
    ).

%% JSON error reply with status remap (503 -> 529) + retry-after header.
anthropic_json_reply(Status0, Reason, _Req, Headers0) ->
    {Status, BodyStatus, Headers} = anthropic_overload_remap(Status0, Headers0),
    Body = anthropic_error_body_h(BodyStatus, Reason, Headers),
    livery_resp:json(Status, Headers, json:encode(Body)).

anthropic_json_reply_h(Status0, Reason, Headers0) ->
    {Status, BodyStatus, Headers} = anthropic_overload_remap(Status0, Headers0),
    Body = anthropic_error_body_h(BodyStatus, Reason, Headers),
    livery_resp:json(Status, Headers, json:encode(Body)).

anthropic_overload_remap(503, Headers) ->
    {529, 529, [retry_after_header() | Headers]};
anthropic_overload_remap(529, Headers) ->
    {529, 529, [retry_after_header() | Headers]};
anthropic_overload_remap(Status, Headers) ->
    {Status, Status, Headers}.

retry_after_header() ->
    Seconds = barrel_inference_server_config:anthropic_retry_after_seconds(),
    {<<"retry-after">>, integer_to_binary(Seconds)}.

anthropic_error_body(Status, Reason, S) ->
    anthropic_error_body_h(Status, Reason, S#st.extra_headers).

anthropic_error_body_h(Status, Reason, Headers) ->
    Base = #{
        <<"type">> => <<"error">>,
        <<"error">> => #{
            <<"type">> => anthropic_error_type(Status),
            <<"message">> => error_message(Reason)
        }
    },
    case proplists:get_value(<<"request-id">>, Headers) of
        undefined -> Base;
        Id -> Base#{<<"request_id">> => Id}
    end.

error_message(request_too_large) ->
    Max = barrel_inference_server_config:max_request_body_bytes(),
    iolist_to_binary(
        io_lib:format("request body too large: max ~B bytes", [Max])
    );
error_message({context_overflow, Tokens, Ctx}) ->
    iolist_to_binary(
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum", [Tokens, Ctx]
        )
    );
error_message({error, {decode_failed, _}}) ->
    error_message(decode_failed);
error_message({decode_failed, _}) ->
    error_message(decode_failed);
error_message(decode_failed) ->
    <<"the model was overloaded and could not process this request; please retry">>;
error_message(Reason) ->
    to_bin(Reason).

anthropic_error_type(400) -> <<"invalid_request_error">>;
anthropic_error_type(401) -> <<"authentication_error">>;
anthropic_error_type(403) -> <<"permission_error">>;
anthropic_error_type(404) -> <<"not_found_error">>;
anthropic_error_type(413) -> <<"request_too_large">>;
anthropic_error_type(429) -> <<"rate_limit_error">>;
anthropic_error_type(501) -> <<"api_error">>;
anthropic_error_type(503) -> <<"overloaded_error">>;
anthropic_error_type(504) -> <<"timeout_error">>;
anthropic_error_type(529) -> <<"overloaded_error">>;
anthropic_error_type(_) -> <<"api_error">>.

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
