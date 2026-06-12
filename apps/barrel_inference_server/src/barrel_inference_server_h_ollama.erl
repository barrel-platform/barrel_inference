%%% Ollama-compatible /api/generate and /api/chat handlers.
%%%
%%% Two endpoints, one module - they share request parsing, the
%%% pipeline lifecycle, and the keep_alive plumbing, and only differ
%%% in the response framing (generate emits `response` deltas; chat
%%% emits `message.content` deltas).
%%%
%%% Empty `prompt` (generate) or empty `messages` (chat) short-
%%% circuits to a preload: the pipeline's load phase runs, the
%%% keepalive timer is refreshed, and the handler emits a single
%%% `{done: true, done_reason: "load" | "unload"}` envelope.
%%%
%%% Real inference threads through the same pipeline as
%%% barrel_inference_server_h_chat but emits NDJSON per token instead of SSE
%%% chunks. Streaming is on by default (Ollama convention).

-module(barrel_inference_server_h_ollama).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% livery entry points (one per route binding in
%% barrel_inference_server_routes:livery_routes/0).
-export([generate/1, chat/1]).

-include("barrel_inference_server.hrl").

-record(st, {
    op :: generate | chat,
    req_id :: binary(),
    model :: binary(),
    requested :: binary(),
    stream :: boolean(),
    is_preload :: boolean(),
    keep_alive_ms :: non_neg_integer() | infinity,
    %% pipeline
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
    %% timing (monotonic ms)
    mono_start :: integer(),
    mono_loaded :: integer() | undefined,
    %% accumulation
    buf :: iodata(),
    stream_started :: boolean(),
    out_tokens :: non_neg_integer()
}).

%%====================================================================
%% Livery entry (route handlers per
%% barrel_inference_server_routes:livery_routes/0). Coexists with the
%% cowboy init/2 below; the routes table picks which one a request
%% lands on depending on which listener answered.
%%====================================================================

generate(Req) ->
    handle_livery(Req, generate).

chat(Req) ->
    handle_livery(Req, chat).

handle_livery(Req, Op) ->
    case livery_req:method(Req) of
        <<"POST">> -> handle_livery_post(Req, Op);
        _ -> livery_resp:json(405, json:encode(#{<<"error">> => <<"method_not_allowed">>}))
    end.

handle_livery_post(Req, Op) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Body, _Req1} ->
            livery_fast_phase(Body, Op);
        {too_large, _Req1} ->
            livery_resp:json(413, json:encode(#{<<"error">> => <<"request_too_large">>}))
    end.

livery_fast_phase(Body, Op) ->
    case decode(Body) of
        {ok, Map} -> livery_translate(Map, Op);
        error -> livery_resp:json(400, json:encode(#{<<"error">> => <<"invalid_json">>}))
    end.

livery_translate(Map, Op) ->
    Translated =
        case Op of
            generate -> barrel_inference_server_translate:ollama_generate_to_internal(Map);
            chat -> barrel_inference_server_translate:ollama_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R} -> livery_start(R, Op);
        {error, Reason} -> livery_resp:json(400, json:encode(error_body(Reason)))
    end.

livery_start(R0, Op) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    KeepAlive = effective_keep_alive(R1#barrel_inference_request.keep_alive_ms),
    case R1#barrel_inference_request.is_preload of
        true -> livery_preload(Op, R1, KeepAlive);
        false -> livery_inference(Op, R1, KeepAlive)
    end.

%% Preload short-circuit on the livery side: the handler process owns
%% the load-progress receive itself (no separate worker), so this is a
%% straight receive loop ending in a one-shot livery_resp:json response.
livery_preload(Op, R, KeepAlive) ->
    Model = R#barrel_inference_request.model_id,
    MonoStart = mono_ms(),
    case barrel_inference_server_config:ensure_loaded_async(Model, self(), preload_deadline()) of
        ok ->
            livery_wait_preload(Op, Model, KeepAlive, MonoStart);
        {error, Reason} ->
            livery_resp:json(error_status(Reason), json:encode(error_body(Reason)))
    end.

livery_wait_preload(Op, Model, KeepAlive, MonoStart) ->
    receive
        {barrel_inference_load_progress, Model} ->
            livery_wait_preload(Op, Model, KeepAlive, MonoStart);
        {barrel_inference_load_done, Model, ok} ->
            NowMs = mono_ms(),
            LoadDurationNs = (NowMs - MonoStart) * 1_000_000,
            Reason =
                case KeepAlive of
                    0 -> <<"unload">>;
                    _ -> <<"load">>
                end,
            Timings = #{
                total_duration_ns => LoadDurationNs,
                load_duration_ns => LoadDurationNs
            },
            Body = barrel_inference_server_translate:ollama_preload_response(
                Op, Reason, Model, Timings
            ),
            apply_keep_alive(Model, KeepAlive),
            livery_resp:json(200, Body);
        {barrel_inference_load_done, Model, {error, Reason}} ->
            livery_resp:json(error_status(Reason), json:encode(error_body(Reason)))
    after preload_recv_timeout() ->
        livery_resp:json(504, json:encode(#{<<"error">> => <<"model_load_timeout">>}))
    end.

%% Inference: streaming returns livery_resp:stream/3 with the NDJSON
%% producer fun; non-streaming buffers tokens internally and returns a
%% one-shot livery_resp:json.
livery_inference(Op, R, KeepAlive) ->
    case R#barrel_inference_request.stream of
        true ->
            livery_resp:stream(
                200,
                [{<<"content-type">>, <<"application/x-ndjson">>}],
                fun(Emit) -> livery_drive(Op, R, KeepAlive, Emit) end
            );
        false ->
            livery_drive_buffered(Op, R, KeepAlive)
    end.

livery_drive(Op, R, KeepAlive, Emit) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = livery_init_state(Op, R, KeepAlive, Worker, Mon),
    try
        livery_stream_loop(State, Emit)
    after
        cleanup(State)
    end.

livery_drive_buffered(Op, R, KeepAlive) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    State = livery_init_state(Op, R, KeepAlive, Worker, Mon),
    try
        livery_buffered_loop(State)
    after
        cleanup(State)
    end.

livery_init_state(Op, R, KeepAlive, Worker, Mon) ->
    #st{
        op = Op,
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = R#barrel_inference_request.model_id,
        stream = R#barrel_inference_request.stream,
        is_preload = false,
        keep_alive_ms = KeepAlive,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        ref = undefined,
        slot = undefined,
        mono_start = mono_ms(),
        mono_loaded = undefined,
        buf = [],
        stream_started = true,
        out_tokens = 0
    }.

%% Streaming receive loop. Each Emit/1 return value is checked: when
%% the peer disconnects livery surfaces `{error, closed}' and we bail
%% out so the `after cleanup' clause runs.
livery_stream_loop(S, Emit) ->
    receive
        {pipeline, loading, _ModelId} ->
            Line = json:encode(#{
                <<"model">> => S#st.model,
                <<"created_at">> => iso8601_now(),
                <<"status">> => <<"loading">>,
                <<"done">> => false
            }),
            case livery_emit_line(Emit, Line) of
                ok -> livery_stream_loop(S, Emit);
                closed -> S
            end;
        {pipeline, loaded} ->
            ok = barrel_inference_server_keepalive:request_begin(S#st.model),
            livery_stream_loop(
                S#st{phase = waiting_template, mono_loaded = mono_ms()},
                Emit
            );
        {pipeline, templated, _Tokens, _ParamsRef} ->
            livery_stream_loop(S#st{phase = waiting_queue}, Emit);
        {pipeline, queued} ->
            livery_stream_loop(S#st{phase = waiting_admit}, Emit);
        {pipeline, admitted, Ref, Slot} ->
            S1 =
                case S#st.ref of
                    undefined -> S#st{phase = running, ref = Ref, slot = Slot};
                    _ -> S#st{slot = Slot}
                end,
            livery_stream_loop(S1, Emit);
        {pipeline, error, _Status, Reason} ->
            _ = livery_emit_line(Emit, json:encode(error_body(Reason))),
            S;
        {barrel_inference_token, Ref, Tok} ->
            S1 = livery_learn_ref(S, Ref),
            Chunk =
                case S1#st.op of
                    generate ->
                        barrel_inference_server_translate:internal_to_ollama_generate_chunk(
                            Tok, S1#st.req_id, S1#st.model
                        );
                    chat ->
                        barrel_inference_server_translate:internal_to_ollama_chat_chunk(
                            Tok, S1#st.req_id, S1#st.model
                        )
                end,
            case livery_emit_line(Emit, Chunk) of
                ok ->
                    livery_stream_loop(S1#st{out_tokens = S1#st.out_tokens + 1}, Emit);
                closed ->
                    S1
            end;
        {barrel_inference_reasoning_token, Ref, _Tok} ->
            livery_stream_loop(livery_learn_ref(S, Ref), Emit);
        {barrel_inference_done, Ref, Stats} ->
            S1 = livery_learn_ref(S, Ref),
            Final = livery_final_chunk(S1, Stats),
            _ = livery_emit_line(Emit, Final),
            S1;
        {barrel_inference_error, Ref, Reason} ->
            S1 = livery_learn_ref(S, Ref),
            _ = livery_emit_line(Emit, json:encode(error_body(Reason))),
            S1;
        {'DOWN', Mon, process, _Pid, _Reason} when Mon =:= S#st.worker_mon ->
            livery_stream_loop(S#st{worker = undefined, worker_mon = undefined}, Emit);
        {barrel_inference_token_id, _Ref, _Id} ->
            livery_stream_loop(S, Emit);
        _Other ->
            livery_stream_loop(S, Emit)
    end.

%% Buffered (non-stream) receive loop. Accumulates the token text and
%% returns a single livery_resp:json response on done.
livery_buffered_loop(S) ->
    receive
        {pipeline, loading, _ModelId} ->
            livery_buffered_loop(S);
        {pipeline, loaded} ->
            ok = barrel_inference_server_keepalive:request_begin(S#st.model),
            livery_buffered_loop(
                S#st{phase = waiting_template, mono_loaded = mono_ms()}
            );
        {pipeline, templated, _Tokens, _ParamsRef} ->
            livery_buffered_loop(S#st{phase = waiting_queue});
        {pipeline, queued} ->
            livery_buffered_loop(S#st{phase = waiting_admit});
        {pipeline, admitted, Ref, Slot} ->
            S1 =
                case S#st.ref of
                    undefined -> S#st{phase = running, ref = Ref, slot = Slot};
                    _ -> S#st{slot = Slot}
                end,
            livery_buffered_loop(S1);
        {pipeline, error, Status, Reason} ->
            livery_resp:json(Status, json:encode(error_body(Reason)));
        {barrel_inference_token, Ref, Tok} ->
            S1 = livery_learn_ref(S, Ref),
            livery_buffered_loop(
                S1#st{buf = [S1#st.buf, Tok], out_tokens = S1#st.out_tokens + 1}
            );
        {barrel_inference_reasoning_token, Ref, _Tok} ->
            livery_buffered_loop(livery_learn_ref(S, Ref));
        {barrel_inference_done, Ref, Stats} ->
            S1 = livery_learn_ref(S, Ref),
            Timings = compute_timings(S1),
            BodyBin = iolist_to_binary(S1#st.buf),
            Body =
                case S1#st.op of
                    generate ->
                        barrel_inference_server_translate:internal_to_ollama_generate_response(
                            BodyBin, Stats, S1#st.model, Timings
                        );
                    chat ->
                        barrel_inference_server_translate:internal_to_ollama_chat_response(
                            BodyBin, Stats, S1#st.model, Timings
                        )
                end,
            livery_resp:json(200, Body);
        {barrel_inference_error, _Ref, Reason} ->
            livery_resp:json(error_status(Reason), json:encode(error_body(Reason)));
        {'DOWN', Mon, process, _Pid, _Reason} when Mon =:= S#st.worker_mon ->
            livery_buffered_loop(S#st{worker = undefined, worker_mon = undefined});
        {barrel_inference_token_id, _Ref, _Id} ->
            livery_buffered_loop(S);
        _Other ->
            livery_buffered_loop(S)
    end.

livery_final_chunk(S, Stats) ->
    Timings = compute_timings(S),
    case S#st.op of
        generate ->
            barrel_inference_server_translate:internal_to_ollama_generate_final(
                Stats, S#st.req_id, S#st.model, Timings
            );
        chat ->
            barrel_inference_server_translate:internal_to_ollama_chat_final(
                Stats, S#st.req_id, S#st.model, Timings
            )
    end.

livery_learn_ref(S = #st{ref = undefined}, Ref) ->
    S#st{phase = running, ref = Ref};
livery_learn_ref(S, _Ref) ->
    S.

%% Emit one NDJSON line. The terminator is a single LF per the Ollama
%% on-wire convention. Returns ok on success, `closed' if the peer
%% disconnected so the caller can stop the receive loop.
livery_emit_line(Emit, Body) ->
    case Emit([Body, <<"\n">>]) of
        ok -> ok;
        {error, closed} -> closed;
        {error, _} -> closed
    end.

%%====================================================================
%% Cowboy entry
%%====================================================================

init(Req0, Opts = #{op := Op}) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            handle_post(Req0, Opts, Op);
        _ ->
            Reply = cowboy_req:reply(405, json_headers(), <<>>, Req0),
            {ok, Reply, Opts}
    end.

handle_post(Req0, Opts, Op) ->
    case barrel_inference_server_body:read(Req0) of
        {ok, Body, Req1} ->
            fast_phase(Body, Req1, Opts, Op);
        {too_large, Req1} ->
            reply_json(413, #{<<"error">> => <<"request_too_large">>}, Req1, Opts)
    end.

fast_phase(Body, Req0, Opts, Op) ->
    case decode(Body) of
        {ok, Map} ->
            translate(Map, Req0, Opts, Op);
        error ->
            reply_json(400, #{<<"error">> => <<"invalid_json">>}, Req0, Opts)
    end.

translate(Map, Req0, Opts, Op) ->
    Translated =
        case Op of
            generate -> barrel_inference_server_translate:ollama_generate_to_internal(Map);
            chat -> barrel_inference_server_translate:ollama_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R} -> start(R, Req0, Opts, Op);
        {error, Reason} -> reply_json(400, error_body(Reason), Req0, Opts)
    end.

start(R0, Req0, Opts, Op) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    KeepAlive = effective_keep_alive(R1#barrel_inference_request.keep_alive_ms),
    case R1#barrel_inference_request.is_preload of
        true ->
            do_preload(Req0, Opts, Op, R1, KeepAlive);
        false ->
            do_inference(Req0, Opts, Op, R1, KeepAlive)
    end.

effective_keep_alive(undefined) -> barrel_inference_server_config:keep_alive_default_ms();
effective_keep_alive(V) -> V.

%%====================================================================
%% Preload short-circuit
%%====================================================================

%% No inference: load (or confirm loaded), refresh keep_alive timer,
%% emit the {done: true, done_reason: "load"|"unload"} envelope.
do_preload(Req0, Opts, Op, R, KeepAlive) ->
    ModelId = R#barrel_inference_request.model_id,
    Model = R#barrel_inference_request.model_id,
    MonoStart = mono_ms(),
    case barrel_inference_server_config:ensure_loaded_async(ModelId, self(), preload_deadline()) of
        ok ->
            wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart);
        {error, Reason} ->
            reply_json(error_status(Reason), error_body(Reason), Req0, Opts)
    end.

wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart) ->
    receive
        {barrel_inference_load_progress, ModelId} ->
            wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart);
        {barrel_inference_load_done, ModelId, ok} ->
            emit_preload(Req0, Opts, Op, Model, MonoStart, KeepAlive, <<"load">>);
        {barrel_inference_load_done, ModelId, {error, Reason}} ->
            reply_json(error_status(Reason), error_body(Reason), Req0, Opts)
    after preload_recv_timeout() ->
        reply_json(504, #{<<"error">> => <<"model_load_timeout">>}, Req0, Opts)
    end.

emit_preload(Req0, Opts, Op, Model, MonoStart, KeepAlive, ReasonOk) ->
    NowMs = mono_ms(),
    LoadDurationNs = (NowMs - MonoStart) * 1_000_000,
    Reason =
        case KeepAlive of
            0 -> <<"unload">>;
            _ -> ReasonOk
        end,
    Timings = #{
        total_duration_ns => LoadDurationNs,
        load_duration_ns => LoadDurationNs
    },
    Body = barrel_inference_server_translate:ollama_preload_response(Op, Reason, Model, Timings),
    %% Wire the keep_alive into the per-model counter. For 0 we
    %% unload synchronously so the HTTP response is a real
    %% acknowledgement that the model is gone from memory.
    apply_keep_alive(Model, KeepAlive),
    Req1 = cowboy_req:reply(200, json_headers(), Body, Req0),
    {ok, Req1, Opts}.

apply_keep_alive(Model, 0) ->
    %% Synchronous unload bypasses the keepalive cast queue, so the
    %% HTTP response is a real acknowledgement that the model is
    %% gone from memory.
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
    %% Same budget as the loader's prefill timeout.
    barrel_inference_server_config:prefill_ms().

%%====================================================================
%% Inference path
%%====================================================================

do_inference(Req0, _Opts, Op, R, KeepAlive) ->
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R),
    Stream = R#barrel_inference_request.stream,
    State = #st{
        op = Op,
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = R#barrel_inference_request.model_id,
        stream = Stream,
        is_preload = false,
        keep_alive_ms = KeepAlive,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        ref = undefined,
        slot = undefined,
        mono_start = mono_ms(),
        mono_loaded = undefined,
        buf = [],
        stream_started = false,
        out_tokens = 0
    },
    {cowboy_loop, Req0, State, hibernate}.

%%====================================================================
%% info/3
%%====================================================================

info({pipeline, loading, _ModelId}, Req0, S = #st{stream = true}) ->
    {Req1, S1} = ensure_stream(Req0, S),
    %% Emit a "loading" NDJSON line as a visible keepalive.
    Line = json:encode(#{
        <<"model">> => S1#st.model,
        <<"created_at">> => iso8601_now(),
        <<"status">> => <<"loading">>,
        <<"done">> => false
    }),
    ndjson_line(Req1, Line),
    {ok, Req1, S1, hibernate};
info({pipeline, loading, _}, Req, S) ->
    {ok, Req, S, hibernate};
info({pipeline, loaded}, Req, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template, mono_loaded = mono_ms()}, hibernate};
info({pipeline, templated, _Tokens, _ParamsRef}, Req, S) ->
    {ok, Req, S#st{phase = waiting_queue}, hibernate};
info({pipeline, queued}, Req, S) ->
    {ok, Req, S#st{phase = waiting_admit}, hibernate};
info({pipeline, admitted, Ref, Slot}, Req0, S0) ->
    %% learn_ref/3 may have arrived ahead of us via a token message;
    %% in that case phase/ref are already set and we just attach the
    %% queue slot. Otherwise this is the canonical admit point.
    S1 =
        case S0#st.ref of
            undefined -> S0#st{phase = running, ref = Ref};
            _ -> S0
        end,
    S2 = S1#st{slot = Slot},
    case S2#st.stream of
        true ->
            {Req1, S3} = ensure_stream(Req0, S2),
            {ok, Req1, S3, hibernate};
        false ->
            {ok, Req0, S2, hibernate}
    end;
info({pipeline, error, Status, Reason}, Req0, S = #st{stream_started = true}) ->
    ndjson_line(Req0, json:encode(error_body(Reason))),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S#st{phase = error_response_for(Status, S)}};
info({pipeline, error, Status, Reason}, Req0, S) ->
    Req1 = cowboy_req:reply(Status, json_headers(), json:encode(error_body(Reason)), Req0),
    {stop, Req1, S};
%% Token / done / error messages may arrive BEFORE
%% {pipeline, admitted, ...} because the pipeline worker calls
%% barrel_inference:infer/4 (which immediately starts decoding) and *then*
%% sends `admitted` to the handler. Because the handler is
%% per-request, any barrel_inference_* message in our mailbox is necessarily
%% ours; learn the Ref on first sight via learn_ref/3 instead of
%% guarding on `S#st{ref = Ref}` (which would drop early tokens).
info({barrel_inference_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
info({barrel_inference_reasoning_token, Ref, _Tok}, Req0, S0) ->
    %% Ollama doesn't surface reasoning tokens separately; drop.
    %% Still learn Ref so a subsequent done/error isn't lost if
    %% reasoning happens to arrive first.
    {S, Req} = learn_ref(S0, Req0, Ref),
    {ok, Req, S, hibernate};
info({barrel_inference_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_ok(Req, S, Stats);
info({barrel_inference_error, Ref, Reason}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_err(Req, S, Reason);
info({'DOWN', Mon, process, _Pid, _Reason}, Req, S = #st{worker_mon = Mon}) ->
    %% Pipeline worker exited after admit; ignore.
    {ok, Req, S#st{worker = undefined, worker_mon = undefined}, hibernate};
%% barrel_inference 0.2.0 emits a token-id message alongside every token text
%% message. We do not consume it.
info({barrel_inference_token_id, _Ref, _Id}, Req, S) ->
    {ok, Req, S, hibernate};
info(_Msg, Req, S) ->
    {ok, Req, S, hibernate}.

terminate(_Reason, _Req, S = #st{}) ->
    cleanup(S),
    ok;
terminate(_, _, _) ->
    ok.

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

%%====================================================================
%% Token handling
%%====================================================================

handle_token(Tok, Req, S = #st{stream = true, op = Op}) ->
    {Req1, S1} = ensure_stream(Req, S),
    Chunk =
        case Op of
            generate ->
                barrel_inference_server_translate:internal_to_ollama_generate_chunk(
                    Tok, S1#st.req_id, S1#st.model
                );
            chat ->
                barrel_inference_server_translate:internal_to_ollama_chat_chunk(
                    Tok, S1#st.req_id, S1#st.model
                )
        end,
    ndjson_line(Req1, Chunk),
    {ok, Req1, S1#st{out_tokens = S1#st.out_tokens + 1}, hibernate};
handle_token(Tok, Req, S = #st{stream = false}) ->
    {ok, Req, S#st{buf = [S#st.buf, Tok], out_tokens = S#st.out_tokens + 1}, hibernate}.

finish_ok(Req0, S = #st{stream = true, op = Op}, Stats) ->
    Timings = compute_timings(S),
    Final =
        case Op of
            generate ->
                barrel_inference_server_translate:internal_to_ollama_generate_final(
                    Stats, S#st.req_id, S#st.model, Timings
                );
            chat ->
                barrel_inference_server_translate:internal_to_ollama_chat_final(
                    Stats, S#st.req_id, S#st.model, Timings
                )
        end,
    {Req1, _S1} = ensure_stream(Req0, S),
    ndjson_line(Req1, Final),
    cowboy_req:stream_body(<<>>, fin, Req1),
    {stop, Req1, S};
finish_ok(Req0, S = #st{stream = false, op = Op}, Stats) ->
    Timings = compute_timings(S),
    BodyBin = iolist_to_binary(S#st.buf),
    Body =
        case Op of
            generate ->
                barrel_inference_server_translate:internal_to_ollama_generate_response(
                    BodyBin, Stats, S#st.model, Timings
                );
            chat ->
                barrel_inference_server_translate:internal_to_ollama_chat_response(
                    BodyBin, Stats, S#st.model, Timings
                )
        end,
    Req1 = cowboy_req:reply(200, json_headers(), Body, Req0),
    {stop, Req1, S}.

finish_err(Req0, S = #st{stream_started = true}, Reason) ->
    ndjson_line(Req0, json:encode(error_body(Reason))),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S};
finish_err(Req0, S = #st{}, Reason) ->
    Req1 = cowboy_req:reply(
        error_status(Reason), json_headers(), json:encode(error_body(Reason)), Req0
    ),
    {stop, Req1, S}.

compute_timings(S) ->
    Now = mono_ms(),
    Total = (Now - S#st.mono_start) * 1_000_000,
    Load =
        case S#st.mono_loaded of
            undefined -> 0;
            T -> (T - S#st.mono_start) * 1_000_000
        end,
    #{total_duration_ns => Total, load_duration_ns => Load}.

%%====================================================================
%% Helpers
%%====================================================================

ensure_stream(Req, S = #st{stream_started = true}) ->
    {Req, S};
ensure_stream(Req0, S) ->
    Req1 = cowboy_req:stream_reply(200, ndjson_headers(), Req0),
    {Req1, S#st{stream_started = true}}.

%% Record the inference Ref on first sight. The pipeline worker
%% sends `admitted` *after* starting `barrel_inference:infer/4`, so token /
%% done / error messages can land before `admitted` and would
%% otherwise be silently dropped by the catch-all clause. For
%% streaming requests also open the NDJSON stream here so the first
%% chunk can flush immediately. Idempotent when admit arrived first.
learn_ref(S = #st{ref = undefined, stream = true}, Req0, Ref) ->
    {Req1, S1} = ensure_stream(Req0, S),
    {S1#st{phase = running, ref = Ref}, Req1};
learn_ref(S = #st{ref = undefined}, Req0, Ref) ->
    {S#st{phase = running, ref = Ref}, Req0};
learn_ref(S, Req, _Ref) ->
    {S, Req}.

ndjson_line(Req, Body) ->
    cowboy_req:stream_body([Body, <<"\n">>], nofin, Req),
    ok.

ndjson_headers() ->
    #{<<"content-type">> => <<"application/x-ndjson">>}.

json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.

reply_json(Status, Body, Req0, Opts) ->
    Req1 = cowboy_req:reply(Status, json_headers(), json:encode(Body), Req0),
    {ok, Req1, Opts}.

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
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum",
            [Tokens, Ctx]
        )
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

error_response_for(_Status, S) ->
    S#st.phase.

mono_ms() ->
    erlang:monotonic_time(millisecond).

iso8601_now() ->
    Now = erlang:system_time(second),
    {{Y, Mo, D}, {H, M, S}} = calendar:system_time_to_universal_time(Now, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, M, S])
    ).
