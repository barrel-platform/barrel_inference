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
%%% erllama_server_h_chat but emits NDJSON per token instead of SSE
%%% chunks. Streaming is on by default (Ollama convention).

-module(erllama_server_h_ollama).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

-include("erllama_server.hrl").

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
    slot :: erllama_server_queue:slot() | undefined,
    %% timing (monotonic ms)
    mono_start :: integer(),
    mono_loaded :: integer() | undefined,
    %% accumulation
    buf :: iodata(),
    stream_started :: boolean(),
    out_tokens :: non_neg_integer()
}).

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
    MaxBody = erllama_server_config:max_request_body_bytes(),
    case cowboy_req:read_body(Req0, #{length => MaxBody}) of
        {ok, Body, Req1} ->
            fast_phase(Body, Req1, Opts, Op);
        {more, _, Req1} ->
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
            generate -> erllama_server_translate:ollama_generate_to_internal(Map);
            chat -> erllama_server_translate:ollama_chat_to_internal(Map)
        end,
    case Translated of
        {ok, R} -> start(R, Req0, Opts, Op);
        {error, Reason} -> reply_json(400, error_body(Reason), Req0, Opts)
    end.

start(R0, Req0, Opts, Op) ->
    Requested = R0#erllama_request.model_id,
    Real = erllama_server_config:resolve_model(Requested),
    R1 = R0#erllama_request{model_id = Real},
    KeepAlive = effective_keep_alive(R1#erllama_request.keep_alive_ms),
    case R1#erllama_request.is_preload of
        true ->
            do_preload(Req0, Opts, Op, R1, KeepAlive);
        false ->
            do_inference(Req0, Opts, Op, R1, KeepAlive)
    end.

effective_keep_alive(undefined) -> erllama_server_config:keep_alive_default_ms();
effective_keep_alive(V) -> V.

%%====================================================================
%% Preload short-circuit
%%====================================================================

%% No inference: load (or confirm loaded), refresh keep_alive timer,
%% emit the {done: true, done_reason: "load"|"unload"} envelope.
do_preload(Req0, Opts, Op, R, KeepAlive) ->
    ModelId = R#erllama_request.model_id,
    Model = R#erllama_request.model_id,
    MonoStart = mono_ms(),
    case erllama_server_config:ensure_loaded_async(ModelId, self(), preload_deadline()) of
        ok ->
            wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart);
        {error, Reason} ->
            reply_json(error_status(Reason), error_body(Reason), Req0, Opts)
    end.

wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart) ->
    receive
        {erllama_load_progress, ModelId} ->
            wait_preload_done(Req0, Opts, Op, ModelId, Model, KeepAlive, MonoStart);
        {erllama_load_done, ModelId, ok} ->
            emit_preload(Req0, Opts, Op, Model, MonoStart, KeepAlive, <<"load">>);
        {erllama_load_done, ModelId, {error, Reason}} ->
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
    Body = erllama_server_translate:ollama_preload_response(Op, Reason, Model, Timings),
    %% Wire the keep_alive into the per-model counter. The
    %% request_begin then immediate request_end with KeepAlive
    %% triggers the configured eviction (0 unloads now, infinity
    %% never).
    ok = erllama_server_keepalive:request_begin(Model),
    ok = erllama_server_keepalive:request_end(Model, KeepAlive),
    Req1 = cowboy_req:reply(200, json_headers(), Body, Req0),
    {ok, Req1, Opts}.

preload_deadline() ->
    erlang:monotonic_time(millisecond) + erllama_server_config:prefill_ms().

preload_recv_timeout() ->
    %% Same budget as the loader's prefill timeout.
    erllama_server_config:prefill_ms().

%%====================================================================
%% Inference path
%%====================================================================

do_inference(Req0, _Opts, Op, R, KeepAlive) ->
    {Worker, Mon} = erllama_server_pipeline:start_link(self(), R),
    Stream = R#erllama_request.stream,
    State = #st{
        op = Op,
        req_id = R#erllama_request.request_id,
        model = R#erllama_request.model_id,
        requested = R#erllama_request.model_id,
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
    ok = erllama_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template, mono_loaded = mono_ms()}, hibernate};
info({pipeline, templated, _}, Req, S) ->
    {ok, Req, S#st{phase = waiting_queue}, hibernate};
info({pipeline, queued}, Req, S) ->
    {ok, Req, S#st{phase = waiting_admit}, hibernate};
info({pipeline, admitted, Ref, Slot}, Req0, S0) ->
    S1 = S0#st{ref = Ref, slot = Slot, phase = running},
    case S1#st.stream of
        true ->
            {Req1, S2} = ensure_stream(Req0, S1),
            {ok, Req1, S2, hibernate};
        false ->
            {ok, Req0, S1, hibernate}
    end;
info({pipeline, error, Status, Reason}, Req0, S = #st{stream_started = true}) ->
    ndjson_line(Req0, json:encode(error_body(Reason))),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S#st{phase = error_response_for(Status, S)}};
info({pipeline, error, Status, Reason}, Req0, S) ->
    Req1 = cowboy_req:reply(Status, json_headers(), json:encode(error_body(Reason)), Req0),
    {stop, Req1, S};
info({erllama_token, Ref, Tok}, Req0, S = #st{ref = Ref}) ->
    handle_token(Tok, Req0, S);
info({erllama_reasoning_token, _Ref, _Tok}, Req, S) ->
    %% Ollama doesn't surface reasoning tokens separately; drop.
    {ok, Req, S, hibernate};
info({erllama_done, Ref, Stats}, Req0, S = #st{ref = Ref}) ->
    finish_ok(Req0, S, Stats);
info({erllama_error, Ref, Reason}, Req0, S = #st{ref = Ref}) ->
    finish_err(Req0, S, Reason);
info({'DOWN', Mon, process, _Pid, _Reason}, Req, S = #st{worker_mon = Mon}) ->
    %% Pipeline worker exited after admit; ignore.
    {ok, Req, S#st{worker = undefined, worker_mon = undefined}, hibernate};
info(_Msg, Req, S) ->
    {ok, Req, S, hibernate}.

terminate(_Reason, _Req, S = #st{}) ->
    cleanup(S),
    ok;
terminate(_, _, _) ->
    ok.

cleanup(S) ->
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
    keepalive_release(S#st.model, S#st.phase, S#st.keep_alive_ms).

keepalive_release(_Model, waiting_load, _KA) ->
    ok;
keepalive_release(Model, _Phase, KA) ->
    erllama_server_keepalive:request_end(Model, KA).

%%====================================================================
%% Token handling
%%====================================================================

handle_token(Tok, Req, S = #st{stream = true, op = Op}) ->
    {Req1, S1} = ensure_stream(Req, S),
    Chunk =
        case Op of
            generate ->
                erllama_server_translate:internal_to_ollama_generate_chunk(
                    Tok, S1#st.req_id, S1#st.model
                );
            chat ->
                erllama_server_translate:internal_to_ollama_chat_chunk(
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
                erllama_server_translate:internal_to_ollama_generate_final(
                    Stats, S#st.req_id, S#st.model, Timings
                );
            chat ->
                erllama_server_translate:internal_to_ollama_chat_final(
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
                erllama_server_translate:internal_to_ollama_generate_response(
                    BodyBin, Stats, S#st.model, Timings
                );
            chat ->
                erllama_server_translate:internal_to_ollama_chat_response(
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
    Req1 = cowboy_req:reply(500, json_headers(), json:encode(error_body(Reason)), Req0),
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
error_body(T) ->
    #{<<"error">> => iolist_to_binary(io_lib:format("~p", [T]))}.

error_status(not_found) -> 404;
error_status(not_preloaded) -> 503;
error_status(not_loaded) -> 503;
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
