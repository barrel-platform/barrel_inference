%%% OpenAI /v1/responses handler.
%%%
%%% Same pipeline as /v1/chat/completions (load, template, queue,
%%% admit, stream tokens) but with the Responses wire shape:
%%%
%%%   - Non-streaming: one JSON envelope `{"id":"resp_...", "object":
%%%     "response", "output":[...], "usage":{...}}`.
%%%   - Streaming: named SSE events (`response.created`,
%%%     `response.output_item.added`, `response.output_text.delta`,
%%%     `response.completed`, ...) - one event per stage.
%%%
%%% Tool-call mode (model with `tool_call_markers` configured) emits a
%%% function_call output item via the response.* event family; the
%%% legacy first-byte heuristic remains for models without the marker
%%% configured.

-module(erllama_server_h_responses).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% Mirrors the pragma in erllama_server_h_chat / h_messages.
-dialyzer({nowarn_function, info/3}).

-include("erllama_server.hrl").

-record(st, {
    %% identity
    req_id :: binary(),
    model :: binary(),
    requested :: binary(),
    api :: openai,
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
    %% buffer for non-streaming text accumulation
    buf_text :: iodata(),
    %% true once we've emitted response.content_part.added for a text
    %% part on the streaming path
    started_text_part = false :: boolean(),
    %% mode (text vs tool-call buffering)
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    stream_started = false :: boolean(),
    received_done = false :: boolean(),
    session_id = undefined :: undefined | binary(),
    %% Full input conversation (post previous_response_id expansion),
    %% in internal `#{role, content}' shape. The assistant reply is
    %% appended and the whole thing stored for the next turn's lookup.
    conv = [] :: [map()],
    %% Responses-specific state
    response_id :: binary() | undefined,
    msg_id :: binary() | undefined,
    out_index = 0 :: non_neg_integer(),
    content_index = 0 :: non_neg_integer(),
    %% List of completed function_call output items (each is a map
    %% ready to slot into the response's `output` array).
    fc_items = [] :: [map()],
    %% Wire-driven tool-call format spec and last captured tool_use
    %% block (mirrors h_chat / h_messages).
    tool_format = undefined :: undefined | erllama_server_tool_format:spec(),
    captured_tool_use = undefined ::
        undefined | #{id := binary(), name := binary(), input := map()}
}).

%%====================================================================
%% init
%%====================================================================

init(Req0, Opts) ->
    %% Echo the OpenAI organization header when the client supplies it.
    %% Some OpenAI SDKs read it back for diagnostics.
    Req1 =
        case cowboy_req:header(<<"openai-organization">>, Req0, undefined) of
            undefined -> Req0;
            Org -> cowboy_req:set_resp_header(<<"openai-organization">>, Org, Req0)
        end,
    case cowboy_req:method(Req1) of
        <<"POST">> -> handle_post(Req1, Opts);
        _ -> reply_405(Req1)
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
    case erllama_server_translate:openai_responses_to_internal(Map) of
        {ok, R0} ->
            R1 = expand_previous_response(Map, R0),
            R2 = R1#erllama_request{
                session_id = erllama_server_session:derive(Req0, R1)
            },
            start_pipeline(R2, Api, Req0);
        {error, {builtin_tool_not_supported, _} = Reason} ->
            reply_json_error(501, Reason, Req0);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    end.

%% Prepend the stored conversation for `previous_response_id' so the
%% chat template renders the full history. A miss (TTL evict, restart,
%% unknown id) proceeds without expansion - the client's `input'
%% already replays the conversation in that case.
expand_previous_response(Map, R) ->
    case maps:get(<<"previous_response_id">>, Map, undefined) of
        Id when is_binary(Id), Id =/= <<>> ->
            case erllama_server_response_store:get(Id) of
                {ok, {_Model, Prior}} ->
                    R#erllama_request{messages = Prior ++ R#erllama_request.messages};
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

start_pipeline(R0, Api, Req0) ->
    Requested = R0#erllama_request.model_id,
    Real = erllama_server_config:resolve_model(Requested),
    R1 = R0#erllama_request{model_id = Real},
    {WorkerPid, Mon} = erllama_server_pipeline:start_link(self(), R1),
    State0 = init_state(R1, Requested, Api, WorkerPid, Mon),
    State = arm_total_timer(State0),
    {cowboy_loop, Req0, State, hibernate}.

init_state(R, Requested, Api, Worker, Mon) ->
    erllama_server_metrics:inc_active_streams(R#erllama_request.model_id),
    #st{
        req_id = R#erllama_request.request_id,
        model = R#erllama_request.model_id,
        requested = Requested,
        api = Api,
        stream = R#erllama_request.stream,
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
        mode = text,
        grammar_set = grammar_active(R),
        session_id = R#erllama_request.session_id,
        conv = R#erllama_request.messages,
        response_id = erllama_server_translate:make_id(<<"resp_">>),
        msg_id = erllama_server_translate:make_id(<<"msg_">>),
        tool_format = resolve_tool_format(R#erllama_request.model_id)
    }.

resolve_tool_format(ModelId) ->
    case erllama_server_tool_format:lookup(ModelId) of
        {ok, Spec} -> Spec;
        not_found -> undefined
    end.

grammar_active(#erllama_request{tools = undefined}) -> false;
grammar_active(#erllama_request{tools = []}) -> false;
grammar_active(#erllama_request{tool_choice = none}) -> false;
grammar_active(_) -> true.

%%====================================================================
%% info/3
%%====================================================================

info({pipeline, loading, _ModelId}, Req0, S0 = #st{stream = true}) ->
    %% Open the stream early so the connection stays warm. No payload;
    %% an SSE comment doubles as a keepalive.
    {Req1, S1} = ensure_stream(Req0, S0),
    ok = sse_comment(Req1, <<"loading">>),
    {ok, Req1, S1, hibernate};
info({pipeline, loading, _ModelId}, Req, S) ->
    {ok, Req, S, hibernate};
info({pipeline, loaded}, Req, S) ->
    ok = erllama_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template}, hibernate};
info({pipeline, templated, _Tokens}, Req, S) ->
    {ok, Req, S#st{phase = waiting_queue}, hibernate};
info({pipeline, queued}, Req, S) ->
    {ok, Req, S#st{phase = waiting_admit}, hibernate};
info({pipeline, admitted, Ref, Slot}, Req0, S0) ->
    S1 =
        case S0#st.ref of
            undefined -> arm_prefill_timer(S0#st{phase = running, ref = Ref});
            _ -> S0
        end,
    S2 = monitor_engine(S1#st{slot = Slot}),
    case S2#st.stream of
        true ->
            {Req1, S3} = ensure_stream(Req0, S2),
            S4 = emit_response_created(Req1, S3),
            S5 = emit_message_added(Req1, S4),
            S6 = emit_content_added(Req1, S5),
            {ok, Req1, S6, hibernate};
        false ->
            {ok, Req0, S2, hibernate}
    end;
info({pipeline, error, Status, Reason}, Req0, S = #st{stream_started = true}) ->
    %% Post-stream error: emit a response.failed SSE frame, close.
    record_metrics(S, Status),
    Payload = erllama_server_translate:internal_to_responses_failed(
        S#st.response_id,
        S#st.requested,
        error_code(Reason),
        error_message(Reason)
    ),
    cowboy_req:stream_body(
        erllama_server_translate:responses_event(<<"response.failed">>, Payload),
        nofin,
        Req0
    ),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S};
info({pipeline, error, Status, Reason}, Req0, S) ->
    record_metrics(S, Status),
    Req1 = json_error(Status, Reason, Req0),
    {stop, Req1, S};
info({'DOWN', Mon, process, _Pid, _Reason}, Req0, S = #st{engine_mon = Mon}) ->
    self() ! {pipeline, error, 500, model_crashed},
    {ok, Req0, S#st{engine_mon = undefined}, hibernate};
info(
    {'DOWN', Mon, process, Worker, _Reason},
    Req0,
    S = #st{worker = Worker, worker_mon = Mon}
) ->
    case S#st.phase of
        running ->
            {ok, Req0, S#st{worker = undefined, worker_mon = undefined}, hibernate};
        _ ->
            Req1 = json_error(500, pipeline_crashed, Req0),
            {stop, Req1, S}
    end;
%% Token messages may arrive before {pipeline, admitted, ...}.
info({erllama_token, Ref, {tool_call_delta, _Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    {ok, Req, rearm_idle(first_token(S)), hibernate};
info({erllama_tool_call_end, Ref, FullBin}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_tool_call_end(FullBin, Req, S);
info({erllama_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
info({erllama_reasoning_token, _Ref, _Tok}, Req, S) ->
    %% Reasoning is not surfaced on the Responses wire (no
    %% reasoning_content field). Drop.
    {ok, Req, S, hibernate};
info({erllama_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    record_session_committed(S, Stats),
    finish_ok(Req, demonitor_engine(S#st{received_done = true}), Stats);
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
info(total_request_timeout, Req, S = #st{phase = running, ref = Ref}) when
    is_reference(Ref)
->
    erllama:cancel(Ref),
    finish_err(Req, S, total_timeout);
info(total_request_timeout, Req0, S) ->
    Req1 = json_error(504, total_timeout, Req0),
    record_metrics(S, 504),
    {stop, Req1, S};
info({erllama_token_id, _Ref, _Id}, Req, S) ->
    {ok, Req, S, hibernate};
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
    maybe_end_session(S),
    keepalive_release(S#st.model, S#st.phase),
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

keepalive_release(_Model, waiting_load) ->
    ok;
keepalive_release(Model, _Phase) ->
    erllama_server_keepalive:request_end(
        Model, erllama_server_config:keep_alive_default_ms()
    ).

%%====================================================================
%% Token handling
%%====================================================================

handle_token(Tok, Req, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
    %% First token under grammar: if it's a JSON `{` switch to
    %% tool_buffer mode (legacy heuristic, used when no
    %% tool_call_markers is configured for the model).
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
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text, Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate};
handle_token(Tok, Req, S = #st{mode = text, out_tokens = 0}) ->
    emit_text(Tok, Req, first_token(S));
handle_token(Tok, Req, S = #st{mode = text}) ->
    emit_text(Tok, Req, S).

emit_text(Tok, Req, S = #st{stream = true}) ->
    Payload = erllama_server_translate:internal_to_responses_text_delta(
        S#st.out_index, S#st.content_index, Tok
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.output_text.delta">>, Payload
    ),
    cowboy_req:stream_body(Frame, nofin, Req),
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text, Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate};
emit_text(Tok, Req, S = #st{stream = false}) ->
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text, Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate}.

%%====================================================================
%% Tool-call (wire-driven path; erllama 0.5+)
%%====================================================================

handle_tool_call_end(FullBin, Req, S = #st{tool_format = Spec, model = Model}) ->
    {Name, Input} = parse_full_bin(Spec, FullBin),
    FcId = erllama_server_translate:make_id(<<"fc_">>),
    CallId = erllama_server_translate:make_id(<<"call_">>),
    maybe_persist_replay(Spec, FcId, Model, FullBin, Name, Input),
    Captured = #{id => FcId, name => Name, input => Input},
    emit_function_call(Req, S, FcId, CallId, Name, Input, Captured).

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

maybe_persist_replay(undefined, _FcId, _Model, _FullBin, _Name, _Input) ->
    ok;
maybe_persist_replay(_Spec, FcId, Model, FullBin, Name, Input) ->
    erllama_server_tool_replay:put(
        FcId,
        Model,
        FullBin,
        #{name => Name, arguments => Input}
    ).

%% Streaming: close the text part / message item first so the
%% function_call item gets its own out_index. Emit the four-event
%% function_call sequence (added, args.delta, args.done, item.done).
%% Non-streaming: stash the captured tool_use; finish_ok builds the
%% final output array from buf_text + captured + fc_items.
emit_function_call(Req, S = #st{stream = true}, FcId, CallId, Name, Input, Captured) ->
    %% Close the in-flight text message if one is open.
    S1 = close_open_message_stream(Req, S),
    OutIdx = S1#st.out_index,
    ArgsBin = iolist_to_binary(json:encode(Input)),
    AddedPayload = erllama_server_translate:internal_to_responses_function_call_added(
        OutIdx, FcId, CallId, Name
    ),
    DeltaPayload = erllama_server_translate:internal_to_responses_function_args_delta(
        OutIdx, ArgsBin
    ),
    DonePayload = erllama_server_translate:internal_to_responses_function_args_done(
        OutIdx, ArgsBin
    ),
    ItemDonePayload =
        (erllama_server_translate:internal_to_responses_function_call_done(
            OutIdx, FcId, CallId, Name
        ))#{
            <<"item">> => fc_item_map(FcId, CallId, Name, ArgsBin)
        },
    Frames = [
        erllama_server_translate:responses_event(
            <<"response.output_item.added">>, AddedPayload
        ),
        erllama_server_translate:responses_event(
            <<"response.function_call_arguments.delta">>, DeltaPayload
        ),
        erllama_server_translate:responses_event(
            <<"response.function_call_arguments.done">>, DonePayload
        ),
        erllama_server_translate:responses_event(
            <<"response.output_item.done">>, ItemDonePayload
        )
    ],
    cowboy_req:stream_body(Frames, nofin, Req),
    FcItem = fc_item_map(FcId, CallId, Name, ArgsBin),
    {ok, Req,
        rearm_idle(S1#st{
            captured_tool_use = Captured,
            fc_items = S1#st.fc_items ++ [FcItem],
            out_index = OutIdx + 1
        }), hibernate};
emit_function_call(Req, S = #st{stream = false}, FcId, CallId, Name, Input, Captured) ->
    ArgsBin = iolist_to_binary(json:encode(Input)),
    FcItem = fc_item_map(FcId, CallId, Name, ArgsBin),
    {ok, Req,
        rearm_idle(S#st{
            captured_tool_use = Captured,
            mode = tool_buffer,
            fc_items = S#st.fc_items ++ [FcItem]
        }), hibernate}.

fc_item_map(FcId, CallId, Name, ArgsBin) ->
    #{
        <<"type">> => <<"function_call">>,
        <<"id">> => FcId,
        <<"call_id">> => CallId,
        <<"name">> => Name,
        <<"arguments">> => ArgsBin,
        <<"status">> => <<"completed">>
    }.

%% On a streaming turn that already has the message item open, close
%% the text part and the message before the function_call item begins.
close_open_message_stream(Req, S = #st{started_text_part = true}) ->
    Text = iolist_to_binary(S#st.buf_text),
    TextDone = erllama_server_translate:internal_to_responses_text_done(
        S#st.out_index, S#st.content_index, Text
    ),
    ContentDone = erllama_server_translate:internal_to_responses_content_done(
        S#st.out_index, S#st.content_index, Text
    ),
    MsgDone = erllama_server_translate:internal_to_responses_message_done(
        S#st.out_index, S#st.msg_id, Text
    ),
    Frames = [
        erllama_server_translate:responses_event(
            <<"response.output_text.done">>, TextDone
        ),
        erllama_server_translate:responses_event(
            <<"response.content_part.done">>, ContentDone
        ),
        erllama_server_translate:responses_event(
            <<"response.output_item.done">>, MsgDone
        )
    ],
    cowboy_req:stream_body(Frames, nofin, Req),
    S#st{
        started_text_part = false,
        out_index = S#st.out_index + 1,
        buf_text = []
    };
close_open_message_stream(_Req, S) ->
    S.

%%====================================================================
%% Finish
%%====================================================================

finish_ok(Req0, S = #st{stream = true, mode = text}, Stats) ->
    %% Close the text message item (if any) and emit response.completed.
    S1 = close_open_message_stream(Req0, S),
    Items = collect_output_items(S1, iolist_to_binary(S#st.buf_text)),
    CompletedPayload = erllama_server_translate:internal_to_responses_completed(
        S1#st.response_id, S1#st.msg_id, Items, Stats, S1#st.requested
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.completed">>, CompletedPayload
    ),
    cowboy_req:stream_body(Frame, fin, Req0),
    record_success(S1, Stats),
    store_response(S1, Items),
    {stop, Req0, S1};
finish_ok(Req0, S = #st{stream = true, mode = tool_buffer}, Stats0) ->
    %% Legacy first-byte tool buffering: the captured JSON is in buf_text.
    %% Mirror h_chat's tool_buffer finish: parse, build a function_call
    %% item, emit the four events, then response.completed.
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    FcId = erllama_server_translate:make_id(<<"fc_">>),
    CallId = erllama_server_translate:make_id(<<"call_">>),
    %% Close any open text message item first (rare on the legacy path:
    %% under grammar the first token is the `{` so no text part has
    %% opened, but be defensive).
    S1 = close_open_message_stream(Req0, S),
    OutIdx = S1#st.out_index,
    ArgsBin =
        case Input of
            I when is_binary(I) -> I;
            _ -> iolist_to_binary(json:encode(Input))
        end,
    AddedPayload = erllama_server_translate:internal_to_responses_function_call_added(
        OutIdx, FcId, CallId, Name
    ),
    DeltaPayload = erllama_server_translate:internal_to_responses_function_args_delta(
        OutIdx, ArgsBin
    ),
    DonePayload = erllama_server_translate:internal_to_responses_function_args_done(
        OutIdx, ArgsBin
    ),
    ItemDonePayload = #{
        <<"output_index">> => OutIdx,
        <<"item">> => fc_item_map(FcId, CallId, Name, ArgsBin)
    },
    Frames = [
        erllama_server_translate:responses_event(
            <<"response.output_item.added">>, AddedPayload
        ),
        erllama_server_translate:responses_event(
            <<"response.function_call_arguments.delta">>, DeltaPayload
        ),
        erllama_server_translate:responses_event(
            <<"response.function_call_arguments.done">>, DonePayload
        ),
        erllama_server_translate:responses_event(
            <<"response.output_item.done">>, ItemDonePayload
        )
    ],
    cowboy_req:stream_body(Frames, nofin, Req0),
    Stats = maps:put(finish_reason, tool_call, Stats0),
    Items = S1#st.fc_items ++ [fc_item_map(FcId, CallId, Name, ArgsBin)],
    CompletedPayload = erllama_server_translate:internal_to_responses_completed(
        S1#st.response_id, S1#st.msg_id, Items, Stats, S1#st.requested
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.completed">>, CompletedPayload
    ),
    cowboy_req:stream_body(Frame, fin, Req0),
    record_success(S1, Stats),
    store_response(S1, Items),
    {stop, Req0, S1#st{out_index = OutIdx + 1}};
finish_ok(Req0, S = #st{stream = false}, Stats0) ->
    Text = iolist_to_binary(S#st.buf_text),
    {Items, Stats} = nonstream_items(S, Text, Stats0),
    Body = erllama_server_translate:internal_to_responses_object(
        S#st.response_id, S#st.msg_id, Items, Stats, S#st.requested
    ),
    Req1 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    record_success(S, Stats),
    store_response(S, Items),
    {stop, Req1, S}.

%% Persist the full conversation (input + this turn's reply) under the
%% response id so a later `previous_response_id' continues the chain.
store_response(#st{response_id = undefined}, _Items) ->
    ok;
store_response(S = #st{response_id = ResponseId, model = Model}, Items) ->
    Conv = S#st.conv ++ items_to_messages(Items),
    erllama_server_response_store:put(ResponseId, Model, Conv).

%% Convert the response `output' array into internal assistant
%% messages. Text items become an assistant message; function_call
%% items become a stable marker matching the replay shape the
%% translator emits for prior tool calls.
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

%% Build the final output array for streaming `response.completed`. The
%% text message item is rebuilt from buf_text + msg_id; function_call
%% items were collected as they completed.
collect_output_items(S, <<>>) ->
    %% No text was produced; only function_call items (if any).
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

%% Non-streaming items: the assistant message (with the accumulated
%% text) followed by any function_call items captured during the turn.
%% A pure-tool turn has no text; we drop the message item in that case.
nonstream_items(S = #st{mode = tool_buffer, fc_items = []}, _Text, Stats0) ->
    %% Legacy first-byte path: parse buf_text as JSON.
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call_legacy(Json),
    FcId = erllama_server_translate:make_id(<<"fc_">>),
    CallId = erllama_server_translate:make_id(<<"call_">>),
    ArgsBin =
        case Input of
            I when is_binary(I) -> I;
            _ -> iolist_to_binary(json:encode(Input))
        end,
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

finish_err(Req0, S = #st{stream = true}, Reason) ->
    _ = http_status(Reason),
    Payload = erllama_server_translate:internal_to_responses_failed(
        S#st.response_id,
        S#st.requested,
        error_code(Reason),
        error_message(Reason)
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.failed">>, Payload
    ),
    cowboy_req:stream_body(Frame, fin, Req0),
    record_error(S, Reason),
    {stop, Req0, S};
finish_err(Req0, S = #st{stream = false}, Reason) ->
    Status = http_status(Reason),
    Req1 = json_error(Status, Reason, Req0),
    record_error(S, Reason),
    {stop, Req1, S}.

%%====================================================================
%% Stream block helpers
%%====================================================================

emit_response_created(Req, S) ->
    Payload = erllama_server_translate:internal_to_responses_partial(
        S#st.response_id, S#st.requested
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.created">>, Payload
    ),
    cowboy_req:stream_body(Frame, nofin, Req),
    S.

emit_message_added(Req, S) ->
    Payload = erllama_server_translate:internal_to_responses_message_added(
        S#st.out_index, S#st.msg_id
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.output_item.added">>, Payload
    ),
    cowboy_req:stream_body(Frame, nofin, Req),
    S.

emit_content_added(Req, S) ->
    Payload = erllama_server_translate:internal_to_responses_content_added(
        S#st.out_index, S#st.content_index
    ),
    Frame = erllama_server_translate:responses_event(
        <<"response.content_part.added">>, Payload
    ),
    cowboy_req:stream_body(Frame, nofin, Req),
    S#st{started_text_part = true}.

%%====================================================================
%% Timers / monitor / metrics
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

arm_total_timer(S = #st{total_tref = undefined}) ->
    Ms = total_ms(),
    TRef = erlang:send_after(Ms, self(), total_request_timeout),
    S#st{total_tref = TRef}.

total_ms() ->
    case erllama_server_config:total_ms() of
        N when is_integer(N), N > 0 -> N;
        _ -> 1800000
    end.

learn_ref(S = #st{ref = undefined, stream = true}, Req0, Ref) ->
    {Req1, S1} = ensure_stream(Req0, S),
    S2 = arm_prefill_timer(S1#st{phase = running, ref = Ref}),
    S3 = emit_response_created(Req1, S2),
    S4 = emit_message_added(Req1, S3),
    S5 = emit_content_added(Req1, S4),
    {S5, Req1};
learn_ref(S = #st{ref = undefined}, Req0, Ref) ->
    {arm_prefill_timer(S#st{phase = running, ref = Ref}), Req0};
learn_ref(S, Req, _Ref) ->
    {S, Req}.

ensure_stream(Req, S = #st{stream_started = true}) ->
    {Req, S};
ensure_stream(Req0, S) ->
    Req1 = cowboy_req:stream_reply(200, sse_headers(), Req0),
    {Req1, S#st{stream_started = true}}.

sse_comment(Req, Text) ->
    cowboy_req:stream_body([<<": ">>, Text, <<"\n\n">>], nofin, Req),
    ok.

%% Engine gen_statem monitor; copied verbatim from h_messages.
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
    Endpoint = <<"/v1/responses">>,
    erllama_server_metrics:record_request(
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

error_message({context_overflow, Tokens, Ctx}) ->
    iolist_to_binary(
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum",
            [Tokens, Ctx]
        )
    );
error_message({builtin_tool_not_supported, Type}) when is_binary(Type) ->
    <<"built-in tool not supported: ", Type/binary>>;
error_message(Reason) ->
    to_bin(Reason).

error_code({context_overflow, _, _}) -> <<"context_length_exceeded">>;
error_code({builtin_tool_not_supported, _}) -> <<"feature_not_supported">>;
error_code(Reason) -> to_bin(Reason).

error_type(400) -> <<"invalid_request_error">>;
error_type(404) -> <<"invalid_request_error">>;
error_type(429) -> <<"rate_limit_error">>;
error_type(500) -> <<"server_error">>;
error_type(501) -> <<"server_error">>;
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
%% Tool-call buffering (legacy first-byte heuristic)
%%====================================================================

is_tool_first_byte(<<>>) -> false;
is_tool_first_byte(<<C, _/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n -> false;
is_tool_first_byte(<<${, _/binary>>) -> true;
is_tool_first_byte(_) -> false.

parse_tool_call_legacy(JsonBin) ->
    case json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} ->
            {Name, json:encode(Args)};
        _ ->
            {<<"unknown">>, JsonBin}
    end.
