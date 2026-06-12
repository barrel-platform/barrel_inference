%%% Livery-side handler for /api/generate and /api/chat (Ollama).
%%%
%%% Coexists with `barrel_inference_server_h_ollama' (the cowboy
%%% handler) during the cowboy → livery migration: the routes table
%%% picks which one a request lands on depending on which listener
%%% answered. They share the request / response shape exactly; only
%%% the framework call surface differs.

-module(barrel_inference_server_h_ollama_livery).

-export([generate/1, chat/1]).

-include("barrel_inference_server.hrl").

-record(st, {
    op :: generate | chat,
    req_id :: binary(),
    model :: binary(),
    keep_alive_ms :: non_neg_integer() | infinity,
    phase ::
        waiting_load
        | waiting_template
        | waiting_queue
        | waiting_admit
        | running,
    worker :: pid() | undefined,
    worker_mon :: reference() | undefined,
    ref :: reference() | undefined,
    slot :: barrel_inference_server_queue:slot() | undefined,
    mono_start :: integer(),
    mono_loaded :: integer() | undefined,
    buf :: iodata(),
    out_tokens :: non_neg_integer()
}).

generate(Req) ->
    handle(Req, generate).

chat(Req) ->
    handle(Req, chat).

handle(Req, Op) ->
    case livery_req:method(Req) of
        <<"POST">> -> handle_post(Req, Op);
        _ -> livery_resp:json(405, json:encode(#{<<"error">> => <<"method_not_allowed">>}))
    end.

handle_post(Req, Op) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Body, _Req1} ->
            fast_phase(Body, Op);
        {too_large, _Req1} ->
            livery_resp:json(413, json:encode(#{<<"error">> => <<"request_too_large">>}))
    end.

fast_phase(Body, Op) ->
    case decode(Body) of
        {ok, Map} -> translate(Map, Op);
        error -> livery_resp:json(400, json:encode(#{<<"error">> => <<"invalid_json">>}))
    end.

translate(Map, Op) ->
    case ollama_to_internal(Op, Map) of
        {ok, R} -> start(R, Op);
        {error, Reason} -> livery_resp:json(400, json:encode(error_body(Reason)))
    end.

start(R0, Op) ->
    Real = barrel_inference_server_config:resolve_model(R0#barrel_inference_request.model_id),
    R1 = R0#barrel_inference_request{model_id = Real},
    KeepAlive = effective_keep_alive(R1#barrel_inference_request.keep_alive_ms),
    case R1#barrel_inference_request.is_preload of
        true -> preload(Op, R1, KeepAlive);
        false -> inference(Op, R1, KeepAlive)
    end.

%% Preload short-circuit: handler process owns the load-progress
%% receive itself (no pipeline worker), then emits a one-shot json
%% response.
preload(Op, R, KeepAlive) ->
    Model = R#barrel_inference_request.model_id,
    MonoStart = mono_ms(),
    case barrel_inference_server_config:ensure_loaded_async(Model, self(), preload_deadline()) of
        ok -> wait_preload(Op, Model, KeepAlive, MonoStart);
        {error, Reason} -> livery_resp:json(error_status(Reason), json:encode(error_body(Reason)))
    end.

wait_preload(Op, Model, KeepAlive, MonoStart) ->
    receive
        {barrel_inference_load_progress, Model} ->
            wait_preload(Op, Model, KeepAlive, MonoStart);
        {barrel_inference_load_done, Model, ok} ->
            ok_preload(Op, Model, KeepAlive, MonoStart);
        {barrel_inference_load_done, Model, {error, Reason}} ->
            livery_resp:json(error_status(Reason), json:encode(error_body(Reason)))
    after preload_recv_timeout() ->
        livery_resp:json(504, json:encode(#{<<"error">> => <<"model_load_timeout">>}))
    end.

ok_preload(Op, Model, KeepAlive, MonoStart) ->
    LoadDurationNs = (mono_ms() - MonoStart) * 1_000_000,
    Reason =
        case KeepAlive of
            0 -> <<"unload">>;
            _ -> <<"load">>
        end,
    Timings = #{total_duration_ns => LoadDurationNs, load_duration_ns => LoadDurationNs},
    Body = barrel_inference_server_translate:ollama_preload_response(Op, Reason, Model, Timings),
    apply_keep_alive(Model, KeepAlive),
    livery_resp:json(200, Body).

%% Streaming returns livery_resp:stream with the NDJSON producer fun;
%% non-streaming buffers tokens and returns a one-shot json.
inference(Op, R, KeepAlive) ->
    case R#barrel_inference_request.stream of
        true ->
            livery_resp:stream(
                200,
                [{<<"content-type">>, <<"application/x-ndjson">>}],
                fun(Emit) -> drive(Op, R, KeepAlive, Emit) end
            );
        false ->
            drive_buffered(Op, R, KeepAlive)
    end.

drive(Op, R, KeepAlive, Emit) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(Op, R, KeepAlive, Worker, Mon),
    try
        stream_loop(State, Emit)
    after
        cleanup(State)
    end.

drive_buffered(Op, R, KeepAlive) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = init_state(Op, R, KeepAlive, Worker, Mon),
    try
        buffered_loop(State)
    after
        cleanup(State)
    end.

init_state(Op, R, KeepAlive, Worker, Mon) ->
    #st{
        op = Op,
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        keep_alive_ms = KeepAlive,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        ref = undefined,
        slot = undefined,
        mono_start = mono_ms(),
        mono_loaded = undefined,
        buf = [],
        out_tokens = 0
    }.

%% Streaming receive loop. Each Emit/1 return value is checked: when
%% the peer disconnects livery surfaces `{error, closed}' and we bail
%% out so the `after cleanup' clause runs.
stream_loop(S, Emit) ->
    receive
        Msg -> dispatch_stream(Msg, S, Emit)
    after stream_idle_timeout() -> S
    end.

dispatch_stream({pipeline, loading, _Model}, S, Emit) ->
    case emit_line(Emit, loading_line(S)) of
        ok -> stream_loop(S, Emit);
        closed -> S
    end;
dispatch_stream({pipeline, loaded}, S, Emit) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    stream_loop(S#st{phase = waiting_template, mono_loaded = mono_ms()}, Emit);
dispatch_stream({pipeline, templated, _Tokens, _ParamsRef}, S, Emit) ->
    stream_loop(S#st{phase = waiting_queue}, Emit);
dispatch_stream({pipeline, queued}, S, Emit) ->
    stream_loop(S#st{phase = waiting_admit}, Emit);
dispatch_stream({pipeline, admitted, Ref, Slot}, S, Emit) ->
    stream_loop(on_admit(S, Ref, Slot), Emit);
dispatch_stream({pipeline, error, _Status, Reason}, S, Emit) ->
    _ = emit_line(Emit, json:encode(error_body(Reason))),
    S;
dispatch_stream({barrel_inference_token, Ref, Tok}, S, Emit) ->
    S1 = learn_ref(S, Ref),
    Chunk = ollama_chunk(S1#st.op, Tok, S1#st.req_id, S1#st.model),
    case emit_line(Emit, Chunk) of
        ok -> stream_loop(S1#st{out_tokens = S1#st.out_tokens + 1}, Emit);
        closed -> S1
    end;
dispatch_stream({barrel_inference_reasoning_token, Ref, _Tok}, S, Emit) ->
    stream_loop(learn_ref(S, Ref), Emit);
dispatch_stream({barrel_inference_done, Ref, Stats}, S, Emit) ->
    S1 = learn_ref(S, Ref),
    _ = emit_line(Emit, final_chunk(S1, Stats)),
    S1;
dispatch_stream({barrel_inference_error, Ref, Reason}, S, Emit) ->
    S1 = learn_ref(S, Ref),
    _ = emit_line(Emit, json:encode(error_body(Reason))),
    S1;
dispatch_stream({'DOWN', Mon, process, _Pid, _Reason}, S, Emit) when Mon =:= S#st.worker_mon ->
    stream_loop(S#st{worker = undefined, worker_mon = undefined}, Emit);
dispatch_stream(_Other, S, Emit) ->
    stream_loop(S, Emit).

loading_line(S) ->
    json:encode(#{
        <<"model">> => S#st.model,
        <<"created_at">> => iso8601_now(),
        <<"status">> => <<"loading">>,
        <<"done">> => false
    }).

%% Buffered (non-stream) receive loop. Accumulates the token text and
%% returns a single livery_resp:json on done.
buffered_loop(S) ->
    receive
        Msg -> dispatch_buffered(Msg, S)
    after stream_idle_timeout() ->
        livery_resp:json(504, json:encode(#{<<"error">> => <<"idle_timeout">>}))
    end.

dispatch_buffered({pipeline, loading, _Model}, S) ->
    buffered_loop(S);
dispatch_buffered({pipeline, loaded}, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    buffered_loop(S#st{phase = waiting_template, mono_loaded = mono_ms()});
dispatch_buffered({pipeline, templated, _Tokens, _ParamsRef}, S) ->
    buffered_loop(S#st{phase = waiting_queue});
dispatch_buffered({pipeline, queued}, S) ->
    buffered_loop(S#st{phase = waiting_admit});
dispatch_buffered({pipeline, admitted, Ref, Slot}, S) ->
    buffered_loop(on_admit(S, Ref, Slot));
dispatch_buffered({pipeline, error, Status, Reason}, _S) ->
    livery_resp:json(Status, json:encode(error_body(Reason)));
dispatch_buffered({barrel_inference_token, Ref, Tok}, S) ->
    S1 = learn_ref(S, Ref),
    buffered_loop(S1#st{buf = [S1#st.buf, Tok], out_tokens = S1#st.out_tokens + 1});
dispatch_buffered({barrel_inference_reasoning_token, Ref, _Tok}, S) ->
    buffered_loop(learn_ref(S, Ref));
dispatch_buffered({barrel_inference_done, Ref, Stats}, S) ->
    S1 = learn_ref(S, Ref),
    Body = ollama_full_response(
        S1#st.op,
        iolist_to_binary(S1#st.buf),
        Stats,
        S1#st.model,
        compute_timings(S1)
    ),
    livery_resp:json(200, Body);
dispatch_buffered({barrel_inference_error, _Ref, Reason}, _S) ->
    livery_resp:json(error_status(Reason), json:encode(error_body(Reason)));
dispatch_buffered({'DOWN', Mon, process, _Pid, _Reason}, S) when Mon =:= S#st.worker_mon ->
    buffered_loop(S#st{worker = undefined, worker_mon = undefined});
dispatch_buffered(_Other, S) ->
    buffered_loop(S).

final_chunk(S, Stats) ->
    ollama_final_chunk(S#st.op, Stats, S#st.req_id, S#st.model, compute_timings(S)).

learn_ref(S = #st{ref = undefined}, Ref) -> S#st{phase = running, ref = Ref};
learn_ref(S, _Ref) -> S.

on_admit(S = #st{ref = undefined}, Ref, Slot) ->
    S#st{phase = running, ref = Ref, slot = Slot};
on_admit(S, _Ref, Slot) ->
    S#st{slot = Slot}.

emit_line(Emit, Body) ->
    case Emit([Body, <<"\n">>]) of
        ok -> ok;
        {error, _} -> closed
    end.

%% Idle ceiling on the per-request receive loop. The pipeline's own
%% timers normally surface a `{pipeline, error, _, _}' well before
%% this fires; this is a hard backstop.
stream_idle_timeout() ->
    application:get_env(barrel_inference_server, idle_timeout_ms, 1800000).

%%====================================================================
%% Cleanup, error mapping, and small helpers
%%====================================================================

cleanup(S) ->
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
    keepalive_release(S#st.model, S#st.phase, S#st.keep_alive_ms).

keepalive_release(_Model, waiting_load, _KA) ->
    ok;
keepalive_release(Model, _Phase, KA) ->
    barrel_inference_server_keepalive:request_end(Model, KA).

ollama_to_internal(generate, Map) ->
    barrel_inference_server_translate:ollama_generate_to_internal(Map);
ollama_to_internal(chat, Map) ->
    barrel_inference_server_translate:ollama_chat_to_internal(Map).

ollama_chunk(generate, Tok, ReqId, Model) ->
    barrel_inference_server_translate:internal_to_ollama_generate_chunk(Tok, ReqId, Model);
ollama_chunk(chat, Tok, ReqId, Model) ->
    barrel_inference_server_translate:internal_to_ollama_chat_chunk(Tok, ReqId, Model).

ollama_final_chunk(generate, Stats, ReqId, Model, Timings) ->
    barrel_inference_server_translate:internal_to_ollama_generate_final(
        Stats, ReqId, Model, Timings
    );
ollama_final_chunk(chat, Stats, ReqId, Model, Timings) ->
    barrel_inference_server_translate:internal_to_ollama_chat_final(Stats, ReqId, Model, Timings).

ollama_full_response(generate, BodyBin, Stats, Model, Timings) ->
    barrel_inference_server_translate:internal_to_ollama_generate_response(
        BodyBin, Stats, Model, Timings
    );
ollama_full_response(chat, BodyBin, Stats, Model, Timings) ->
    barrel_inference_server_translate:internal_to_ollama_chat_response(
        BodyBin, Stats, Model, Timings
    ).

effective_keep_alive(undefined) -> barrel_inference_server_config:keep_alive_default_ms();
effective_keep_alive(V) -> V.

apply_keep_alive(Model, 0) ->
    try barrel_inference:unload(Model) of
        _ -> ok
    catch
        _:_ -> ok
    end;
apply_keep_alive(Model, KeepAlive) ->
    ok = barrel_inference_server_keepalive:request_begin(Model),
    ok = barrel_inference_server_keepalive:request_end(Model, KeepAlive),
    ok.

preload_deadline() ->
    erlang:monotonic_time(millisecond) + barrel_inference_server_config:prefill_ms().

preload_recv_timeout() ->
    barrel_inference_server_config:prefill_ms().

compute_timings(S) ->
    Now = mono_ms(),
    Total = (Now - S#st.mono_start) * 1_000_000,
    Load =
        case S#st.mono_loaded of
            undefined -> 0;
            T -> (T - S#st.mono_start) * 1_000_000
        end,
    #{total_duration_ns => Total, load_duration_ns => Load}.

decode(Body) ->
    try json:decode(Body) of
        M when is_map(M) -> {ok, M};
        _ -> error
    catch
        _:_ -> error
    end.

error_body(B) when is_binary(B) ->
    #{<<"error">> => B};
error_body(A) when is_atom(A) ->
    #{<<"error">> => atom_to_binary(A, utf8)};
error_body({context_overflow, Tokens, Ctx}) ->
    Msg = iolist_to_binary(
        io_lib:format("prompt is too long: ~B tokens > ~B maximum", [Tokens, Ctx])
    ),
    #{<<"error">> => Msg};
error_body({error, {decode_failed, _}}) ->
    decode_failed_body();
error_body({decode_failed, _}) ->
    decode_failed_body();
error_body(T) ->
    #{<<"error">> => iolist_to_binary(io_lib:format("~p", [T]))}.

decode_failed_body() ->
    #{
        <<"error">> =>
            <<"the model was overloaded and could not process this request; please retry">>
    }.

error_status(not_found) -> 404;
error_status(not_preloaded) -> 503;
error_status(not_loaded) -> 503;
error_status({error, {decode_failed, _}}) -> 503;
error_status({decode_failed, _}) -> 503;
error_status(_) -> 500.

mono_ms() ->
    erlang:monotonic_time(millisecond).

iso8601_now() ->
    Now = erlang:system_time(second),
    {{Y, Mo, D}, {H, M, S}} = calendar:system_time_to_universal_time(Now, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, M, S])
    ).
