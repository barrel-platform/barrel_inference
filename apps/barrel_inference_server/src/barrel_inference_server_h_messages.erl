%%% Anthropic /v1/messages handler.
%%%
%%% Mirrors barrel_inference_server_h_chat for pipeline + admission + token
%%% handling, but emits Anthropic-shaped responses:
%%%
%%%   - Streaming: named SSE events (message_start, content_block_*,
%%%     message_delta, message_stop). No [DONE] sentinel.
%%%   - Non-streaming: `{"type":"message", "content":[{type:"text",...}]}`.
%%%
%%% Tool-call mode (grammar set, first-byte `{`) buffers the JSON and
%%% emits one `content_block_start` of `type:"tool_use"`, one
%%% `content_block_delta` carrying the full `partial_json`, and one
%%% `content_block_stop`.

-module(barrel_inference_server_h_messages).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% See the matching pragma in barrel_inference_server_h_chat.
-dialyzer({nowarn_function, info/3}).

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
    %% Set on {pipeline, admitted, _, _}: monitors the engine
    %% gen_statem for this model so a mid-inference crash surfaces
    %% as 500 model_crashed instead of a hung connection. Cleared
    %% on barrel_inference_done and on terminate/3.
    engine_mon :: reference() | undefined,
    ref :: reference() | undefined,
    slot :: barrel_inference_server_queue:slot() | undefined,
    started_mono :: integer(),
    first_token_at :: integer() | undefined,
    prefill_tref :: reference() | undefined,
    %% Periodic ping during active generation. Anthropic SDKs read the
    %% ping event to reset their idle timer; without this slow models
    %% trip proxy / SDK idle timeouts on long generations.
    gen_ping_tref :: reference() | undefined,
    idle_tref :: reference() | undefined,
    out_tokens :: non_neg_integer(),
    prompt_tokens :: non_neg_integer(),
    buf_text :: iodata(),
    buf_reason :: iodata(),
    mode :: text | tool_buffer,
    grammar_set :: boolean(),
    %% Anthropic-specific stream state. text/thinking block fields
    %% carry the assigned content-block index when the block is open
    %% (Anthropic spec requires monotonically increasing per-block
    %% indices), or undefined when no block of that kind is open.
    total_tref :: reference() | undefined,
    text_block_started :: undefined | non_neg_integer(),
    thinking_block_started :: undefined | non_neg_integer(),
    message_started :: boolean(),
    %% Anthropic prompt-caching markers captured at request-translate
    %% time. Carried forward into Stats so the response/SSE usage
    %% frame can emit the nested cache_creation TTL split.
    cache_hints :: list(),
    %% Optional metadata.user_id from the request body; propagated
    %% from `#barrel_inference_request.user_id` so the per-request structured
    %% log can include it without re-reading the original record.
    user_id = undefined :: undefined | binary(),
    %% Sticky-seq session id derived in the handler's fast phase.
    %% Stashed on #st so cleanup/terminate can call end_session/2
    %% without re-reading the request record.
    session_id = undefined :: undefined | binary(),
    %% Integrity signature for the (currently open or just-closed)
    %% thinking block, captured from the engine's
    %% {barrel_inference_thinking_end, Ref, Sig} message. Forwarded to the
    %% response builder so non-streaming clients see it on the
    %% thinking content block; the streaming path emits it as a
    %% signature_delta SSE event before content_block_stop.
    thinking_signature = undefined :: undefined | binary(),
    %% When `omitted`, thinking_delta SSE frames are not emitted and
    %% the non-streaming response omits the thinking content block
    %% (engine still produces thinking; the wire just hides it).
    thinking_display = visible :: visible | omitted,
    %% true once stream_reply/3 has fired (separate from
    %% message_started, which guards the Anthropic message_start
    %% event). Loading-phase pings can open the stream before the
    %% canonical message_start frame.
    stream_started = false :: boolean(),
    %% true once an `barrel_inference_done' message has been observed for the
    %% inference ref. When terminate/3 fires without this flag set,
    %% the request was cancelled (TCP close, timeout, ...) mid-flight
    %% and the engine still has the seq pinned to the request's
    %% sticky session. Calling end_session in cleanup frees the seq
    %% so the next request - on any session - can admit. Naturally-
    %% completed turns leave the session pinned for cross-turn reuse.
    received_done = false :: boolean(),
    %% barrel_inference 0.5.0 wire-driven tool-call state. When the model has
    %% `tool_call_markers' set on load_model/2, the engine emits
    %% `{tool_call_delta, _}' / `{barrel_inference_tool_call_end, _, FullBin}'
    %% instead of routing tool JSON through the legacy first-byte
    %% heuristic. We cache the resolved format spec at admission so
    %% the hot path doesn't re-read the manifest per request, and
    %% remember a captured tool_use block until finish_ok emits it
    %% (non-streaming) or after the SSE emit (streaming, observability
    %% only).
    tool_format = undefined :: undefined | barrel_inference_server_tool_format:spec(),
    %% barrel_inference 0.8 wire capture accumulates ALL tool calls the model
    %% emits in one generation (it can emit several `<tool_call>' spans
    %% on free decode). Dispatched once on barrel_inference_done: server-targeted
    %% calls run concurrently and the turn continues; client calls are
    %% surfaced as N tool_use blocks.
    captured_calls = [] ::
        [#{id := binary(), name := binary(), input := map(), full_bin := binary()}],
    %% Streaming tool-call text scanner for the native `tool_mode' path
    %% (model emits calls as text); undefined on the grammar path.
    tool_scan = undefined :: undefined | barrel_inference_server_tool_scan:state(),
    %% Built-in tools the server executes in-process, keyed by the
    %% model-facing name. Empty unless an executor is registered.
    server_tools = #{} :: #{binary() => barrel_inference_server_tool_executor:spec()},
    %% Agentic continue-loop state (engages only on a server_tools hit):
    %% run the executors server-side and re-invoke with the results
    %% appended, until the model answers without a server tool or the
    %% cap is hit. Mirrors barrel_inference_server_h_responses / h_chat.
    tool_iter = 0 :: non_neg_integer(),
    max_tool_iter = 5 :: pos_integer(),
    loop_request = undefined :: undefined | #barrel_inference_request{},
    loop_messages = [] :: [map()],
    %% One server-tool batch in flight: the coordinator's batch ref and
    %% the calls it is running (so the result round can append an
    %% assistant + tool message per call). exec_mon monitors the
    %% coordinator; exec_tref bounds the whole batch.
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
    %% Rendered prompt token ids for the current round (the `prompt_tokens'
    %% field above is just their count, for usage reporting). With
    %% Stats.generated on barrel_inference_done they form the session's committed
    %% token-id list for the byte-exact continuation path.
    prompt_token_ids = [] :: [non_neg_integer()]
}).

%%====================================================================
%% init
%%====================================================================

init(Req0, Opts) ->
    %% Echo the anthropic-version request header onto the response.
    %% Anthropic SDKs send this on every request and read it back to
    %% guard against accidental cross-version proxies. Default to the
    %% baseline 2023-06-01 if the client omitted it.
    Version = cowboy_req:header(<<"anthropic-version">>, Req0, <<"2023-06-01">>),
    Req1 = cowboy_req:set_resp_header(<<"anthropic-version">>, Version, Req0),
    %% Anthropic SDKs read `request-id` (no x- prefix) into
    %% message._request_id for support diagnostics. The global middleware
    %% has already stamped the configured header (x-request-id by
    %% default); alias the literal request-id name with the same value
    %% so SDK callers see a populated _request_id.
    Req2 = mirror_request_id(Req1),
    case check_api_key(Req2) of
        ok ->
            case cowboy_req:method(Req2) of
                <<"POST">> ->
                    handle_post(Req2, Opts);
                _ ->
                    Req3 = cowboy_req:reply(405, #{}, <<>>, Req2),
                    {ok, Req3, Opts}
            end;
        unauthorized ->
            reply_json_error(401, authentication_error, Req2)
    end.

%% When `anthropic_api_keys` is configured (non-empty list), the
%% x-api-key header must match one of the entries. When unset (default)
%% the endpoint is open so Claude Code with any literal API key value
%% (including its placeholder `not-used`) hits the model without
%% friction. Tighten via app env for public deployments.
check_api_key(Req) ->
    case barrel_inference_server_config:anthropic_api_keys() of
        [] ->
            ok;
        Allowed ->
            case cowboy_req:header(<<"x-api-key">>, Req, undefined) of
                undefined ->
                    unauthorized;
                Key ->
                    case lists:member(Key, Allowed) of
                        true -> ok;
                        false -> unauthorized
                    end
            end
    end.

mirror_request_id(Req) ->
    case cowboy_req:resp_header(<<"x-request-id">>, Req, undefined) of
        undefined -> Req;
        Id -> cowboy_req:set_resp_header(<<"request-id">>, Id, Req)
    end.

handle_post(Req0, Opts) ->
    case barrel_inference_server_body:read(Req0) of
        {ok, Body, Req1} -> fast_phase(Body, Req1, Opts);
        {too_large, Req1} -> reply_json_error(413, request_too_large, Req1)
    end.

fast_phase(Body, Req0, Opts) ->
    case decode(Body) of
        {ok, Map} -> translate(Map, Req0, Opts);
        error -> reply_json_error(400, invalid_json, Req0)
    end.

translate(Map, Req0, Opts) ->
    case barrel_inference_server_translate:anthropic_messages_to_internal(Map) of
        {ok, R} ->
            %% Anthropic surfaces beta opt-ins on both the
            %% `anthropic-beta` header (comma-separated) and the body
            %% `betas` array. Merge both into one de-duplicated list
            %% on the request record. Observability-only for now; the
            %% engine has no beta-feature pass-through.
            R1 = R#barrel_inference_request{
                anthropic_betas = collect_betas(Req0, Map)
            },
            %% Derive the sticky-seq session id before the pipeline
            %% sees the record so build_params/1 forwards it as the
            %% `Params.session_id' key on `barrel_inference:infer/4'.
            R2 = R1#barrel_inference_request{
                session_id = barrel_inference_server_session:derive(Req0, R1)
            },
            dispatch(R2, Req0, Opts);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    end.

collect_betas(Req, Body) ->
    Header = cowboy_req:header(<<"anthropic-beta">>, Req, <<>>),
    FromHeader = [
        trim(B)
     || B <- binary:split(Header, <<",">>, [global]), trim(B) =/= <<>>
    ],
    FromBody = barrel_inference_server_translate:parse_anthropic_betas_body(Body),
    lists:usort(FromHeader ++ FromBody).

trim(Bin) when is_binary(Bin) ->
    list_to_binary(string:trim(binary_to_list(Bin))).

dispatch(R, Req0, #{op := count_tokens}) ->
    count_tokens(R, Req0);
dispatch(R, Req0, _Opts) ->
    start_pipeline(R, Req0).

%% Anthropic's /v1/messages/count_tokens: same body shape as
%% /v1/messages, returns `{"input_tokens": N}`. No inference, no
%% queue slot, no streaming. The tokenizer is the model's BPE
%% table inside the GGUF, so we need the model loaded; if it isn't,
%% return 503 rather than load on demand — count_tokens is meant
%% to be CHEAP.
count_tokens(R0, Req0) ->
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
            Req1 = cowboy_req:reply(
                200,
                #{<<"content-type">> => <<"application/json">>},
                Body,
                Req0
            ),
            {ok, Req1, undefined};
        {error, no_template} ->
            reply_json_error(501, no_chat_template, Req0);
        {error, not_supported} ->
            reply_json_error(501, chat_template_not_supported, Req0);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    catch
        exit:{noproc, {barrel_inference_model, not_found, _}} ->
            reply_json_error(503, not_loaded, Req0);
        _Class:_Why ->
            reply_json_error(500, model_crashed, Req0)
    end.

start_pipeline(R0, Req0) ->
    Requested = R0#barrel_inference_request.model_id,
    Real = barrel_inference_server_config:resolve_model(Requested),
    R1 = R0#barrel_inference_request{model_id = Real},
    {Worker, Mon} = barrel_inference_server_pipeline:start_link(self(), R1),
    State0 = init_state(R1, Requested, Worker, Mon),
    State = arm_total_timer(State0),
    {cowboy_loop, Req0, State, hibernate}.

arm_total_timer(S = #st{total_tref = undefined}) ->
    Ms =
        case barrel_inference_server_config:total_ms() of
            N when is_integer(N), N > 0 -> N;
            _ -> 1800000
        end,
    TRef = erlang:send_after(Ms, self(), total_request_timeout),
    S#st{total_tref = TRef}.

init_state(R, Requested, Worker, Mon) ->
    barrel_inference_server_metrics:inc_active_streams(R#barrel_inference_request.model_id),
    #st{
        req_id = R#barrel_inference_request.request_id,
        model = R#barrel_inference_request.model_id,
        requested = Requested,
        stream = R#barrel_inference_request.stream,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
        engine_mon = undefined,
        ref = undefined,
        slot = undefined,
        started_mono = mono_ms(),
        first_token_at = undefined,
        prefill_tref = undefined,
        gen_ping_tref = undefined,
        idle_tref = undefined,
        total_tref = undefined,
        out_tokens = 0,
        prompt_tokens = 0,
        buf_text = [],
        buf_reason = [],
        mode = text,
        grammar_set =
            grammar_active(R) andalso
                barrel_inference_server_tool_format:native_turn(R) =:= none,
        text_block_started = undefined,
        thinking_block_started = undefined,
        message_started = false,
        cache_hints = R#barrel_inference_request.cache_hints,
        thinking_display = R#barrel_inference_request.thinking_display,
        user_id = R#barrel_inference_request.user_id,
        session_id = R#barrel_inference_request.session_id,
        tool_format = resolve_tool_format(R#barrel_inference_request.model_id),
        tool_scan = init_tool_scan(R),
        server_tools = R#barrel_inference_request.server_tools,
        max_tool_iter = barrel_inference_server_config:max_tool_iterations(),
        loop_request = R,
        loop_messages = R#barrel_inference_request.messages
    }.

%% Build the streaming text scanner iff this is the native tool path.
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

%% Mirrors barrel_inference_server_grammar:from_tools/2: no grammar is installed
%% when tools is empty/missing or tool_choice is the explicit `none`.
grammar_active(#barrel_inference_request{tools = undefined}) -> false;
grammar_active(#barrel_inference_request{tools = []}) -> false;
grammar_active(#barrel_inference_request{tool_choice = none}) -> false;
grammar_active(_) -> true.

%%====================================================================
%% info/3
%%====================================================================

info({pipeline, loading, _ModelId}, Req0, S0 = #st{stream = true}) ->
    %% Long load: emit an Anthropic `event: ping` every tick. The
    %% Anthropic SDK recognises this and resets its idle timer.
    {Req1, S1} = ensure_stream(Req0, S0),
    ok = anthropic_ping(Req1),
    {ok, Req1, S1, hibernate};
info({pipeline, loading, _ModelId}, Req, S) ->
    {ok, Req, S, hibernate};
info({pipeline, loaded}, Req, S = #st{keepalive_begun = true}) ->
    %% Later loop round re-loading; keepalive already counted.
    {ok, Req, S#st{phase = waiting_template}, hibernate};
info({pipeline, loaded}, Req, S) ->
    ok = barrel_inference_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template, keepalive_begun = true}, hibernate};
info({pipeline, templated, Tokens}, Req, S) ->
    %% Capture the prompt token count for the message_start frame's
    %% `usage.input_tokens`. Without this, streaming clients see 0
    %% in message_start while non-streaming reports the real value.
    {ok, Req,
        S#st{
            phase = waiting_queue,
            prompt_tokens = length(Tokens),
            prompt_token_ids = Tokens
        },
        hibernate};
info({pipeline, queued}, Req, S) ->
    {ok, Req, S#st{phase = waiting_admit}, hibernate};
info({pipeline, admitted, Ref, Slot}, Req0, S0) ->
    %% Tokens may have arrived first via learn_ref/3. If so, just
    %% attach the slot.
    S1 =
        case S0#st.ref of
            undefined -> arm_prefill(S0#st{phase = running, ref = Ref});
            _ -> S0
        end,
    S2 = monitor_engine(S1#st{slot = Slot}),
    case S2#st.stream of
        true ->
            {Req1, S3} = ensure_stream(Req0, S2),
            S4 = emit_message_start(Req1, S3),
            {ok, Req1, S4, hibernate};
        false ->
            {ok, Req0, S2, hibernate}
    end;
info({pipeline, error, Status, Reason}, Req0, S = #st{stream_started = true}) ->
    %% Post-stream: emit an Anthropic error event, close the body.
    record_metrics(S, Status),
    anthropic_event(Req0, <<"error">>, anthropic_error_body(Status, Reason, Req0)),
    cowboy_req:stream_body(<<>>, fin, Req0),
    {stop, Req0, S};
info({pipeline, error, Status, Reason}, Req0, S = #st{stream = true}) ->
    %% Pre-stream error on a streaming request: open the SSE channel
    %% and emit the `event: error` frame so Anthropic SDKs see a
    %% proper stream-error event instead of a JSON envelope they
    %% can't decode as SSE.
    record_metrics(S, Status),
    {Req1, S1} = ensure_stream(Req0, S),
    anthropic_event(Req1, <<"error">>, anthropic_error_body(Status, Reason, Req1)),
    cowboy_req:stream_body(<<>>, fin, Req1),
    {stop, Req1, S1};
info({pipeline, error, Status, Reason}, Req0, S) ->
    record_metrics(S, Status),
    Req1 = stamp_ratelimit(Req0, S#st.model),
    Req2 = json_error(Status, Reason, Req1),
    {stop, Req2, S};
info(
    {'DOWN', Mon, process, _Pid, _Reason},
    Req0,
    S = #st{engine_mon = Mon}
) ->
    %% Engine gen_statem crashed mid-inference (e.g. decode_failed in
    %% the NIF). Reroute to the existing pipeline-error path so the
    %% client sees 500 model_crashed instead of a hung connection.
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
%% Token messages may arrive before {pipeline, admitted, ...} (see
%% the matching comment in barrel_inference_server_h_chat).
%% barrel_inference 0.3.0 carries extended-thinking deltas inside the same
%% `barrel_inference_token` tag using a {thinking_delta, Bin} payload (the
%% engine's `thinking => enabled` Params hook); plain binary payloads
%% are text fragments.
info({barrel_inference_token, Ref, {thinking_delta, Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Bin, Req, S);
%% barrel_inference 0.5.0: per-chunk tool-call payload. The full body is also
%% delivered as a single binary on the matching `barrel_inference_tool_call_end'
%% message, so the deltas themselves are no-ops here - we just
%% acknowledge them and let `learn_ref' record the slot ref.
info({barrel_inference_token, Ref, {tool_call_delta, _Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    {ok, Req, rearm_idle(first_token(S)), hibernate};
info({barrel_inference_token, Ref, Tok}, Req0, S0) when is_binary(Tok) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
%% Legacy reasoning-token tag for backends that emit reasoning out of
%% band; harmless if never fired.
info({barrel_inference_reasoning_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Tok, Req, S);
%% barrel_inference 0.3.0 emits exactly one close marker per thinking block,
%% carrying an opaque integrity signature. The Anthropic spec requires
%% a `signature_delta` SSE event before the matching `content_block_stop`.
info({barrel_inference_thinking_end, Ref, Sig}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_thinking_end(Sig, Req, S);
%% barrel_inference 0.5.0: tool-call span complete. FullBin is every delta
%% concatenated. We parse it via the per-model format module, mint a
%% tool id, emit the Anthropic tool_use SSE frames (streaming) or
%% stash the captured block for finish_ok (non-streaming), and
%% persist {ToolId, Model, FullBin, Json} in the exact-replay map
%% so PR 6's render path can splice the verbatim bytes back on the
%% next turn.
info({barrel_inference_tool_call_end, Ref, FullBin}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_tool_call_end(FullBin, Req, S);
info({barrel_inference_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    record_session_committed(S, Stats),
    S1 = accumulate_stats(S, Stats),
    case S1#st.pending_exec of
        undefined ->
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
info({prefill_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, prefill_timeout);
info({idle_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, generation_idle_timeout);
info({gen_ping, Ref}, Req, S = #st{ref = Ref, stream_started = true}) ->
    %% Cadence keepalive while generation is active. Re-arm and emit
    %% only when the stream is open; ignore stale messages.
    ok = anthropic_ping(Req),
    {ok, Req, arm_gen_ping(S), hibernate};
info({gen_ping, _}, Req, S) ->
    {ok, Req, S, hibernate};
info(total_request_timeout, Req, S = #st{phase = running, ref = Ref}) when is_reference(Ref) ->
    barrel_inference:cancel(Ref),
    finish_err(Req, S, total_timeout);
info(total_request_timeout, Req0, S) ->
    Req1 = json_error(504, total_timeout, Req0),
    record_metrics(S, 504),
    {stop, Req1, S};
%% barrel_inference 0.2.0 emits a token-id message alongside every token text
%% message. We do not consume it.
info({barrel_inference_token_id, _Ref, _Id}, Req, S) ->
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
    case S#st.slot of
        undefined -> ok;
        Slot -> barrel_inference_server_queue:release(S#st.model, Slot)
    end,
    %% If the request was cancelled mid-flight (TCP close, timeout,
    %% pipeline crash) the engine still has the seq pinned to this
    %% request's sticky session. Free it so the next request - on
    %% any session - can admit. Cleanly-completed turns
    %% (received_done = true) leave the pinned session alive for
    %% cross-turn KV reuse.
    maybe_end_session(S),
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
    %% Mirror the engine's cleanup on our side: cancel-mid-flight
    %% leaves no useful prior count for the next turn.
    barrel_inference_server_session_state:delete(Model, SessionId),
    ok.

%% Store the session's committed token-id list (rendered prompt ++
%% generated) so the next turn can verify a byte-exact continuation
%% before routing through `barrel_inference:continue/3'. Skip when no session
%% id is on file (legacy path); the guard lives in session_state.
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

%% Native tool path: route every token through the streaming scanner. It
%% separates content (emitted as text deltas / buffered) from tool calls
%% (accumulated into captured_calls); the engine emits no marker events
%% here because the model writes its calls as ordinary text tokens.
handle_token(Tok, Req, S0 = #st{tool_scan = Scan}) when Scan =/= undefined ->
    {Emits, Scan1} = barrel_inference_server_tool_scan:feed(Scan, Tok),
    S = first_token(S0#st{tool_scan = Scan1}),
    apply_scan_emits(Emits, Req, S);
handle_token(Tok, Req, S = #st{out_tokens = 0, mode = text, grammar_set = true}) ->
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

emit_text(Tok, Req, S) ->
    {ok, Req, rearm_idle(stream_text(Tok, Req, S)), hibernate}.

%% Emit one text fragment (streaming delta or buffered) and return the
%% updated state - the reusable core of emit_text, also used to apply the
%% scanner's {text,_} emits.
stream_text(<<>>, _Req, S) ->
    S;
stream_text(Tok, Req, S = #st{stream = true}) ->
    S1 = ensure_text_block_started(Req, S),
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {text_delta, Tok, S1#st.text_block_started}, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    S1#st{out_tokens = S1#st.out_tokens + 1};
stream_text(Tok, _Req, S = #st{stream = false}) ->
    S#st{buf_text = [S#st.buf_text, Tok], out_tokens = S#st.out_tokens + 1}.

%% Apply scanner emits: text -> the content path, tool -> captured_calls
%% (parsed name/args + verbatim raw bytes for replay + the continue-loop).
apply_scan_emits(Emits, Req, S0) ->
    S = lists:foldl(fun(E, Sx) -> apply_scan_emit(E, Req, Sx) end, S0, Emits),
    {ok, Req, rearm_idle(S), hibernate}.

apply_scan_emit({text, Bin}, Req, S) ->
    stream_text(Bin, Req, S);
apply_scan_emit({tool, #{name := Name, arguments := Args, raw := Raw}}, _Req, S) ->
    ToolId = make_tool_id(),
    maybe_persist_replay(S#st.tool_format, ToolId, S#st.model, Raw, Name, Args),
    Call = #{id => ToolId, name => Name, input => Args, full_bin => Raw},
    S#st{captured_calls = S#st.captured_calls ++ [Call]}.

%% At end-of-generation, flush the scanner's held tail (trailing content,
%% or a completed call that hadn't been followed by more text). No-op off
%% the native path.
flush_scan(_Req, S = #st{tool_scan = undefined}) ->
    S;
flush_scan(Req, S = #st{tool_scan = Scan}) ->
    {Emits, _} = barrel_inference_server_tool_scan:finish(Scan),
    lists:foldl(fun(E, Sx) -> apply_scan_emit(E, Req, Sx) end, S#st{tool_scan = undefined}, Emits).

%% `thinking_display = omitted` keeps the engine producing thinking
%% but hides it on the wire: no thinking_delta SSE frames, no thinking
%% content block, no signature_delta. The engine still pays the
%% generation cost; only the visible output is suppressed.
handle_reasoning(_Tok, Req, S = #st{thinking_display = omitted}) ->
    {ok, Req, rearm_idle(S), hibernate};
handle_reasoning(Tok, Req, S = #st{stream = true}) ->
    S1 = ensure_thinking_block_started(Req, S),
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {thinking_delta, Tok, S1#st.thinking_block_started},
        #{},
        S#st.req_id,
        S#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    {ok, Req, rearm_idle(S1), hibernate};
handle_reasoning(Tok, Req, S = #st{stream = false}) ->
    {ok, Req, rearm_idle(S#st{buf_reason = [S#st.buf_reason | Tok]}), hibernate}.

%% Streaming: emit `signature_delta` (if a signature was supplied) then
%% close the thinking block. Non-streaming: stash the signature so the
%% response builder can include it on the thinking content block.
handle_thinking_end(_Sig, Req, S = #st{thinking_display = omitted}) ->
    %% Display omitted: thinking block was never opened on the wire,
    %% so there's nothing to close and the signature is discarded.
    {ok, Req, rearm_idle(S), hibernate};
handle_thinking_end(Sig, Req, S = #st{stream = true, thinking_block_started = Index}) when
    is_integer(Index)
->
    case Sig of
        <<>> ->
            ok;
        _ ->
            Delta = #{
                <<"type">> => <<"content_block_delta">>,
                <<"index">> => Index,
                <<"delta">> => #{
                    <<"type">> => <<"signature_delta">>,
                    %% Sig is opaque engine bytes; Anthropic SDKs read
                    %% the signature field as base64.
                    <<"signature">> => base64:encode(Sig)
                }
            },
            cowboy_req:stream_body(
                [
                    <<"event: content_block_delta\ndata: ">>,
                    json:encode(Delta),
                    <<"\n\n">>
                ],
                nofin,
                Req
            )
    end,
    S1 = maybe_close_thinking(Req, S),
    {ok, Req, rearm_idle(S1#st{thinking_signature = Sig}), hibernate};
handle_thinking_end(Sig, Req, S) ->
    %% No thinking block currently open in streaming mode, or
    %% non-streaming mode. Stash the signature for the response
    %% builder.
    {ok, Req, rearm_idle(S#st{thinking_signature = Sig}), hibernate}.

%% Parse FullBin via the per-model format module, mint a tool id,
%% persist for next-turn exact replay, then route to the streaming
%% or non-streaming emit path. When no format is configured for
%% this model we fall back to the legacy `parse_tool_call/1' so a
%% misconfigured operator still gets *something* back, just without
%% replay-map persistence.
%% Accumulate the call; the model may emit several `<tool_call>' spans
%% on free decode. Dispatch (server-exec vs client tool_use) happens
%% once on barrel_inference_done so we know the full batch and can honour
%% parallel_tool_calls. Replay persistence is per-call (client blocks
%% may be replayed from history next turn).
handle_tool_call_end(FullBin, Req, S = #st{tool_format = Spec, model = Model}) ->
    case parse_full_bin(Spec, FullBin) of
        skip ->
            %% Truncated capture (e.g. an empty inter-call span the model
            %% emitted by spamming the start marker). Drop, never surface
            %% to the caller as a fake `unknown({})' tool_use block.
            {ok, Req, rearm_idle(S), hibernate};
        {ok, Name, Input} ->
            ToolId = make_tool_id(),
            maybe_persist_replay(Spec, ToolId, Model, FullBin, Name, Input),
            Call = #{id => ToolId, name => Name, input => Input, full_bin => FullBin},
            {ok, Req, rearm_idle(S#st{captured_calls = S#st.captured_calls ++ [Call]}), hibernate}
    end.

parse_full_bin(undefined, FullBin) ->
    {Name, Args} = parse_tool_call(FullBin),
    {ok, Name, Args};
parse_full_bin(Spec, FullBin) ->
    case barrel_inference_server_tool_format:parse(Spec, FullBin) of
        {ok, #{name := Name, arguments := Args}} ->
            {ok, Name, Args};
        {error, empty_args} ->
            skip;
        {error, _} ->
            {Name, Args} = parse_tool_call(FullBin),
            {ok, Name, Args}
    end.

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
%% No calls -> the legacy first-byte path / plain finish. Otherwise
%% honour parallel_tool_calls, then split the batch: any server-targeted
%% call makes the turn CONTINUE (run all server calls concurrently,
%% re-infer once); a server-free batch FINISHES, surfacing every client
%% call as a tool_use block. A turn never both continues and finishes.
dispatch_done(Req, S = #st{captured_calls = []}) ->
    maybe_legacy_server_tool(Req, S#st{received_done = true});
dispatch_done(Req, S = #st{captured_calls = Calls0}) ->
    Calls = cap_parallel(S, Calls0),
    {ServerCalls, ClientCalls} = partition_calls(Calls, S#st.server_tools),
    case ServerCalls of
        [] -> finish_with_tool_uses(Req, S#st{received_done = true}, ClientCalls);
        _ -> begin_server_tools(ServerCalls, Req, S)
    end.

%% parallel_tool_calls=false (or Anthropic disable_parallel_tool_use):
%% surface only the first call. Grammar is skipped on the native path so
%% the model is free to emit several; the cap is applied at capture.
cap_parallel(#st{loop_request = #barrel_inference_request{parallel_tool_calls = false}}, Calls) ->
    lists:sublist(Calls, 1);
cap_parallel(_S, Calls) ->
    Calls.

partition_calls(Calls, ServerTools) ->
    lists:partition(fun(#{name := N}) -> maps:is_key(N, ServerTools) end, Calls).

%% Legacy first-byte path: the tool JSON is buffered and named only at
%% done. If it names a server tool, run it and continue; else finish.
maybe_legacy_server_tool(Req, S = #st{mode = tool_buffer, server_tools = ST}) when
    map_size(ST) > 0
->
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call(Json),
    case maps:find(Name, ST) of
        {ok, _ExecSpec} ->
            Call = #{id => make_tool_id(), name => Name, input => Input, full_bin => Json},
            begin_server_tools([Call], Req, S);
        error ->
            finish_ok(Req, S#st{received_done = true}, S#st.agg_stats)
    end;
maybe_legacy_server_tool(Req, S) ->
    finish_ok(Req, S#st{received_done = true}, S#st.agg_stats).

%% Run all server-targeted calls concurrently off the handler process
%% via one coordinator; the aggregated results arrive as a single
%% {tool_exec_batch_result, BatchRef, _}. Close any open content block
%% first so the continuation round opens fresh blocks.
begin_server_tools(ServerCalls, Req, S0) ->
    S = close_open_text_or_thinking(Req, S0),
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

%% One assistant message (the verbatim tool-call bytes) + one tool
%% message (the executor result) per call, in submit order. On a batch
%% error (timeout / coordinator crash) every call gets the error as its
%% result so the model can recover.
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

%% Surface every client tool call as a tool_use block and finish the
%% turn (stop_reason = tool_use). Streaming emits N content blocks with
%% sequential indices after closing any open text/thinking block;
%% non-streaming returns them in one response body.
finish_with_tool_uses(Req, S0 = #st{stream = true}, Calls) ->
    S = close_open_text_or_thinking(Req, S0),
    Base = next_block_index(S),
    Frames = tool_use_frames(S, Calls, Base),
    StatsTC = maps:put(finish_reason, tool_call, S#st.agg_stats),
    MsgDelta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(StatsTC, S)}, #{}, S#st.req_id, S#st.requested
    ),
    MsgStop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body([Frames, MsgDelta, MsgStop], fin, Req),
    record_success(S, StatsTC),
    {stop, Req, S};
finish_with_tool_uses(Req0, S = #st{stream = false}, Calls) ->
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
    Req1 = stamp_ratelimit(Req0, S#st.model),
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req1
    ),
    record_success(S, Stats),
    {stop, Req2, S}.

tool_use_frames(S, Calls, Base) ->
    {Frames, _} = lists:mapfoldl(
        fun(Call, Idx) -> {tool_use_frame(S, Idx, Call), Idx + 1} end,
        Base,
        Calls
    ),
    Frames.

tool_use_frame(S, Idx, #{id := Id, name := Name, input := Input}) ->
    Start = #{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Idx,
        <<"content_block">> => #{
            <<"type">> => <<"tool_use">>,
            <<"id">> => Id,
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

close_open_text_or_thinking(Req, S0) ->
    S1 = maybe_close_thinking(Req, S0),
    case S1#st.text_block_started of
        undefined ->
            S1;
        TIdx ->
            Stop = barrel_inference_server_translate:internal_to_anthropic_event(
                {content_block_stop, TIdx}, #{}, S1#st.req_id, S1#st.requested
            ),
            cowboy_req:stream_body(Stop, nofin, Req),
            S1#st{text_block_started = undefined}
    end.

%%====================================================================
%% Stream block management
%%====================================================================

emit_message_start(_Req, S = #st{message_started = true}) ->
    S;
emit_message_start(Req, S) ->
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_start, S#st.prompt_tokens}, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    S#st{message_started = true}.

ensure_text_block_started(_Req, S = #st{text_block_started = I}) when is_integer(I) ->
    S;
ensure_text_block_started(Req, S) ->
    %% Close a thinking block first if one is open.
    S1 = maybe_close_thinking(Req, S),
    Index = next_block_index(S1),
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {content_block_start_text, Index}, #{}, S1#st.req_id, S1#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    S1#st{text_block_started = Index}.

ensure_thinking_block_started(_Req, S = #st{thinking_block_started = I}) when is_integer(I) ->
    S;
ensure_thinking_block_started(Req, S) ->
    Index = next_block_index(S),
    Payload = #{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Index,
        <<"content_block">> =>
            #{<<"type">> => <<"thinking">>, <<"thinking">> => <<>>}
    },
    cowboy_req:stream_body(
        [
            <<"event: content_block_start\ndata: ">>,
            json:encode(Payload),
            <<"\n\n">>
        ],
        nofin,
        Req
    ),
    S#st{thinking_block_started = Index}.

maybe_close_thinking(_Req, S = #st{thinking_block_started = undefined}) ->
    S;
maybe_close_thinking(Req, S = #st{thinking_block_started = Index}) ->
    Iolist = barrel_inference_server_translate:internal_to_anthropic_event(
        {content_block_stop, Index}, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    S#st{thinking_block_started = undefined}.

%% Next monotonic content-block index. The Anthropic spec requires
%% indices to be unique and increasing within a single message; SDK
%% stream accumulators slot-fill `message.content[index]` so reusing
%% an index across distinct blocks corrupts the assembled message.
next_block_index(#st{text_block_started = T, thinking_block_started = K}) ->
    Indices = [I || I <- [T, K], is_integer(I)],
    case Indices of
        [] -> 0;
        _ -> lists:max(Indices) + 1
    end.

%% The index of the currently open content block (text or thinking).
%% Only one of the two is ever open at finish-of-stream time because
%% ensure_text_block_started closes any open thinking block first.
open_block_index(#st{text_block_started = I}) when is_integer(I) -> I;
open_block_index(#st{thinking_block_started = I}) when is_integer(I) -> I;
open_block_index(_) -> undefined.

%% Carry cache_hints from the request through to the response usage
%% builder so it can compute the cache_creation TTL split.
attach_cache_hints(Stats, #st{cache_hints = []}) ->
    Stats;
attach_cache_hints(Stats, #st{cache_hints = Hints}) ->
    Stats#{cache_hints => Hints}.

%%====================================================================
%% Finish
%%====================================================================

finish_ok(Req0, S = #st{stream = true, mode = text}, Stats0) ->
    %% Close any open content block at its assigned index, then
    %% message_delta + message_stop. When the v0.5 wire captured a
    %% tool_use earlier in this turn its block was already closed in
    %% `emit_captured_tool_use', so `open_block_index/1' returns
    %% undefined here; the only additional work is to flip the
    %% finish_reason to `tool_call' for the message_delta frame.
    Stats = maybe_set_tool_call_finish_reason(S, Stats0),
    OpenIdx = open_block_index(S),
    Req1 =
        case OpenIdx of
            undefined ->
                Req0;
            I ->
                StopBlock = barrel_inference_server_translate:internal_to_anthropic_event(
                    {content_block_stop, I}, #{}, S#st.req_id, S#st.requested
                ),
                cowboy_req:stream_body(StopBlock, nofin, Req0),
                Req0
        end,
    Delta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(Stats, S)}, #{}, S#st.req_id, S#st.requested
    ),
    Stop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body([Delta, Stop], fin, Req1),
    record_success(S, Stats),
    {stop, Req1, S};
finish_ok(Req0, S0 = #st{stream = true, mode = tool_buffer}, Stats) ->
    %% Close any open thinking block before opening the tool_use block,
    %% so the tool_use index follows the thinking index monotonically.
    S = maybe_close_thinking(Req0, S0),
    Idx = next_block_index(S),
    Json = iolist_to_binary(S#st.buf_text),
    {Name, Input} = parse_tool_call(Json),
    ToolId = make_tool_id(),
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
    StatsToolCall = maps:put(finish_reason, tool_call, Stats),
    MsgDelta = barrel_inference_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(StatsToolCall, S)},
        #{},
        S#st.req_id,
        S#st.requested
    ),
    MsgStop = barrel_inference_server_translate:internal_to_anthropic_event(
        message_stop, #{}, S#st.req_id, S#st.requested
    ),
    Frames = [
        [<<"event: content_block_start\ndata: ">>, json:encode(Start), <<"\n\n">>],
        [<<"event: content_block_delta\ndata: ">>, json:encode(DeltaInput), <<"\n\n">>],
        Stop,
        MsgDelta,
        MsgStop
    ],
    cowboy_req:stream_body(Frames, fin, Req0),
    record_success(S, Stats),
    {stop, Req0, S};
finish_ok(Req0, S = #st{stream = false}, Stats0) ->
    {Content, Stats} = nonstream_content(S, Stats0),
    Body = barrel_inference_server_translate:internal_to_anthropic_messages_response(
        Content, attach_cache_hints(Stats, S), S#st.requested
    ),
    Req1 = stamp_ratelimit(Req0, S#st.model),
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req1
    ),
    record_success(S, Stats),
    {stop, Req2, S}.

%% Build the non-streaming content list. Streaming-path callers
%% already emit tool_use / thinking blocks separately; the
%% non-streaming path used to flatten everything into a single text
%% block, which lost tool calls and thinking entirely. Return the
%% (possibly amended) Stats so the stop_reason picks up `tool_use`.
%% (barrel_inference 0.8 wire-captured tool calls are surfaced by
%% finish_with_tool_uses, not here.)
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

%% Per Anthropic spec, the thinking block carries a `signature` field
%% when one is available (round-tripped by SDKs on the next turn).
%% Sig is opaque engine bytes; SDKs decode as base64.
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

finish_err(Req0, S = #st{stream = true}, Reason) ->
    Status = http_status(Reason),
    Err = anthropic_error_body(Status, Reason, Req0),
    cowboy_req:stream_body(
        [<<"event: error\ndata: ">>, json:encode(Err), <<"\n\n">>],
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
%% Timers / metrics / shared
%%====================================================================

first_token(S = #st{first_token_at = undefined}) ->
    Now = mono_ms(),
    PrefillSec = (Now - S#st.started_mono) / 1000.0,
    barrel_inference_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    rearm_idle(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

%% See learn_ref/3 in barrel_inference_server_h_chat. For streaming requests
%% also call stream_reply + emit message_start so the body can be
%% sent immediately.
learn_ref(S = #st{ref = undefined, stream = true}, Req0, Ref) ->
    {Req1, S1} = ensure_stream(Req0, S),
    S2 = arm_prefill(S1#st{phase = running, ref = Ref}),
    S3 = emit_message_start(Req1, S2),
    S4 = arm_gen_ping(S3),
    {S4, Req1};
learn_ref(S = #st{ref = undefined}, Req0, Ref) ->
    {arm_prefill(S#st{phase = running, ref = Ref}), Req0};
learn_ref(S, Req, _Ref) ->
    {S, Req}.

%% Open the SSE stream exactly once.
ensure_stream(Req, S = #st{stream_started = true}) ->
    {Req, S};
ensure_stream(Req0, S) ->
    Req1 = stamp_ratelimit(Req0, S#st.model),
    Req2 = cowboy_req:stream_reply(200, sse_headers(), Req1),
    {Req2, S#st{stream_started = true}}.

%% Anthropic SDKs read `anthropic-ratelimit-requests-{limit,remaining,reset}`
%% to throttle their pre-emptive retries. We map the per-model queue
%% snapshot onto these headers; token-bucket headers are omitted since
%% we have no per-minute / per-day token accounting.
stamp_ratelimit(Req, Model) ->
    #{concurrency := Limit, inflight := Inflight} =
        barrel_inference_server_queue:stats(Model),
    Remaining = max(0, Limit - Inflight),
    Reset = ratelimit_reset(),
    Req1 = cowboy_req:set_resp_header(
        <<"anthropic-ratelimit-requests-limit">>, integer_to_binary(Limit), Req
    ),
    Req2 = cowboy_req:set_resp_header(
        <<"anthropic-ratelimit-requests-remaining">>,
        integer_to_binary(Remaining),
        Req1
    ),
    cowboy_req:set_resp_header(
        <<"anthropic-ratelimit-requests-reset">>, Reset, Req2
    ).

ratelimit_reset() ->
    Seconds = barrel_inference_server_config:anthropic_retry_after_seconds(),
    Bin = list_to_binary(
        calendar:system_time_to_rfc3339(erlang:system_time(second) + Seconds, [
            {offset, "Z"}
        ])
    ),
    Bin.

anthropic_ping(Req) ->
    anthropic_event(Req, <<"ping">>, #{<<"type">> => <<"ping">>}).

arm_gen_ping(S = #st{ref = Ref}) when is_reference(Ref) ->
    cancel_timer(S#st.gen_ping_tref),
    Ms = barrel_inference_server_config:generation_ping_ms(),
    S#st{gen_ping_tref = erlang:send_after(Ms, self(), {gen_ping, Ref})};
arm_gen_ping(S) ->
    S.

anthropic_event(Req, EventName, JsonMap) ->
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

arm_prefill(S) ->
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

%% Monitor the engine's gen_statem so a mid-inference crash
%% (e.g. NIF decode_failed) surfaces as 500 model_crashed instead
%% of hanging the handler until the client disconnects. No-op if
%% the engine is no longer registered.
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
    %% Structured per-request log line for observability sinks. user_id
    %% comes from the request's metadata.user_id (undefined when not
    %% set); request_id is the Anthropic-shaped msg_<int> the SDK
    %% surfaces as message._request_id. Emitted at notice level (the
    %% same level as the access log) so the default OTP logger config
    %% picks it up. Kept out of metric labels to avoid Prometheus
    %% cardinality blow-up.
    %%
    %% On 200 paths Stats carries cache_hit_kind (exact|partial|cold|
    %% sticky|continuation) and cache_delta := #{read, created}. The
    %% pair is the answer to "did the engine warm-restore the static
    %% prefix on this turn?" and lets operators measure cross-
    %% conversation prefix reuse without instrumenting the model.
    %% Error paths pass an empty Stats map; cache_* fields land as
    %% undefined / 0 and observability sinks can drop them.
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

reply_json_error(Status, Reason, Req0) ->
    Req1 = json_error(Status, Reason, Req0),
    {ok, Req1, undefined}.

json_error(Status0, Reason, Req0) ->
    {Status, ErrorBodyStatus, Req1} = anthropic_overload_remap(Status0, Req0),
    cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(anthropic_error_body(ErrorBodyStatus, Reason, Req1)),
        Req1
    ).

%% Anthropic prefers HTTP 529 (overloaded_error) over 503 for retryable
%% server-side failures; the SDK gives 529 a longer back-off than the
%% generic 503 path. Translate on the wire and stamp `retry-after` so
%% Claude Code's retry loop lands on the right delay. Cowlib's status
%% table has no 529 entry so we pass the binary form
%% `<<"529 Too Busy">>`; the error-body lookup still wants the
%% integer for anthropic_error_type.
anthropic_overload_remap(503, Req) ->
    {<<"529 Too Busy">>, 529, set_retry_after(Req)};
anthropic_overload_remap(529, Req) ->
    {<<"529 Too Busy">>, 529, set_retry_after(Req)};
anthropic_overload_remap(Status, Req) ->
    {Status, Status, Req}.

set_retry_after(Req) ->
    Seconds = barrel_inference_server_config:anthropic_retry_after_seconds(),
    cowboy_req:set_resp_header(
        <<"retry-after">>, integer_to_binary(Seconds), Req
    ).

%% Shared Anthropic error envelope used by both the JSON pre-stream
%% reply and the SSE `event: error` frame. The spec includes
%% `request_id` in the body alongside the response header; SDKs read
%% both for support diagnostics.
anthropic_error_body(Status, Reason, Req) ->
    Base = #{
        <<"type">> => <<"error">>,
        <<"error">> => #{
            <<"type">> => anthropic_error_type(Status),
            <<"message">> => error_message(Reason)
        }
    },
    case cowboy_req:resp_header(<<"x-request-id">>, Req, undefined) of
        undefined -> Base;
        Id -> Base#{<<"request_id">> => Id}
    end.

%% Human-readable text for the `error.message' field. Clients (and
%% users) see this string directly; the atom name is useful in logs
%% but not as wire copy. Fall back to `to_bin/1' for reasons we have
%% not bothered to humanise yet.
error_message(request_too_large) ->
    Max = barrel_inference_server_config:max_request_body_bytes(),
    iolist_to_binary(
        io_lib:format("request body too large: max ~B bytes", [Max])
    );
error_message({context_overflow, Tokens, Ctx}) ->
    iolist_to_binary(
        io_lib:format(
            "prompt is too long: ~B tokens > ~B maximum",
            [Tokens, Ctx]
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
anthropic_error_type(503) -> <<"overloaded_error">>;
anthropic_error_type(504) -> <<"timeout_error">>;
anthropic_error_type(529) -> <<"overloaded_error">>;
anthropic_error_type(_) -> <<"api_error">>.

http_status(prefill_timeout) -> 504;
http_status(generation_idle_timeout) -> 504;
http_status(total_timeout) -> 504;
%% A recovered decode failure (KV exhaustion under concurrency) is
%% retryable: 503 -> Anthropic `overloaded_error` (529 + Retry-After).
http_status({error, {decode_failed, _}}) -> 503;
http_status({decode_failed, _}) -> 503;
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

parse_tool_call(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"name">> := Name, <<"arguments">> := Args} -> {Name, Args};
        _ -> {<<"unknown">>, JsonBin}
    catch
        _:_ -> {<<"unknown">>, JsonBin}
    end.

%% Wire-captured tool calls are surfaced (and their stop_reason set)
%% by finish_with_tool_uses, so by the time finish_ok runs the list is
%% empty and this is a no-op; kept defensively for the text finish path.
maybe_set_tool_call_finish_reason(#st{captured_calls = []}, Stats) ->
    Stats;
maybe_set_tool_call_finish_reason(_, Stats) ->
    maps:put(finish_reason, tool_call, Stats).

make_tool_id() ->
    iolist_to_binary([
        <<"toolu_">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
