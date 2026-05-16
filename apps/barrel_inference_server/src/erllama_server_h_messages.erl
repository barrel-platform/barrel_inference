%%% Anthropic /v1/messages handler.
%%%
%%% Mirrors erllama_server_h_chat for pipeline + admission + token
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

-module(erllama_server_h_messages).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

%% See the matching pragma in erllama_server_h_chat.
-dialyzer({nowarn_function, info/3}).

-include("erllama_server.hrl").

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
    ref :: reference() | undefined,
    slot :: erllama_server_queue:slot() | undefined,
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
    %% Integrity signature for the (currently open or just-closed)
    %% thinking block, captured from the engine's
    %% {erllama_thinking_end, Ref, Sig} message. Forwarded to the
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
    stream_started = false :: boolean()
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
    case erllama_server_config:anthropic_api_keys() of
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
    MaxBody = erllama_server_config:max_request_body_bytes(),
    case cowboy_req:read_body(Req0, #{length => MaxBody}) of
        {ok, Body, Req1} -> fast_phase(Body, Req1, Opts);
        {more, _, Req1} -> reply_json_error(413, request_too_large, Req1)
    end.

fast_phase(Body, Req0, Opts) ->
    case decode(Body) of
        {ok, Map} -> translate(Map, Req0, Opts);
        error -> reply_json_error(400, invalid_json, Req0)
    end.

translate(Map, Req0, Opts) ->
    case erllama_server_translate:anthropic_messages_to_internal(Map) of
        {ok, R} ->
            %% Capture the optional anthropic-beta request header for
            %% observability (CORS already allows it). Not currently
            %% acted on; the engine has no beta-feature pass-through.
            R1 = R#erllama_request{
                anthropic_beta = cowboy_req:header(
                    <<"anthropic-beta">>, Req0, undefined
                )
            },
            dispatch(R1, Req0, Opts);
        {error, Reason} ->
            reply_json_error(400, Reason, Req0)
    end.

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
    Requested = R0#erllama_request.model_id,
    Real = erllama_server_config:resolve_model(Requested),
    Req = #{
        messages => R0#erllama_request.messages,
        system => R0#erllama_request.system,
        tools => R0#erllama_request.tools
    },
    try erllama:apply_chat_template(Real, Req) of
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
        exit:{noproc, {erllama_model, not_found, _}} ->
            reply_json_error(503, not_loaded, Req0);
        _Class:_Why ->
            reply_json_error(500, model_crashed, Req0)
    end.

start_pipeline(R0, Req0) ->
    Requested = R0#erllama_request.model_id,
    Real = erllama_server_config:resolve_model(Requested),
    R1 = R0#erllama_request{model_id = Real},
    {Worker, Mon} = erllama_server_pipeline:start_link(self(), R1),
    State0 = init_state(R1, Requested, Worker, Mon),
    State = arm_total_timer(State0),
    {cowboy_loop, Req0, State, hibernate}.

arm_total_timer(S = #st{total_tref = undefined}) ->
    Ms =
        case erllama_server_config:total_ms() of
            N when is_integer(N), N > 0 -> N;
            _ -> 1800000
        end,
    TRef = erlang:send_after(Ms, self(), total_request_timeout),
    S#st{total_tref = TRef}.

init_state(R, Requested, Worker, Mon) ->
    erllama_server_metrics:inc_active_streams(R#erllama_request.model_id),
    #st{
        req_id = R#erllama_request.request_id,
        model = R#erllama_request.model_id,
        requested = Requested,
        stream = R#erllama_request.stream,
        phase = waiting_load,
        worker = Worker,
        worker_mon = Mon,
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
        grammar_set = grammar_active(R),
        text_block_started = undefined,
        thinking_block_started = undefined,
        message_started = false,
        cache_hints = R#erllama_request.cache_hints,
        thinking_display = R#erllama_request.thinking_display
    }.

%% Mirrors erllama_server_grammar:from_tools/2: no grammar is installed
%% when tools is empty/missing or tool_choice is the explicit `none`.
grammar_active(#erllama_request{tools = undefined}) -> false;
grammar_active(#erllama_request{tools = []}) -> false;
grammar_active(#erllama_request{tool_choice = none}) -> false;
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
info({pipeline, loaded}, Req, S) ->
    ok = erllama_server_keepalive:request_begin(S#st.model),
    {ok, Req, S#st{phase = waiting_template}, hibernate};
info({pipeline, templated, Tokens}, Req, S) ->
    %% Capture the prompt token count for the message_start frame's
    %% `usage.input_tokens`. Without this, streaming clients see 0
    %% in message_start while non-streaming reports the real value.
    {ok, Req, S#st{phase = waiting_queue, prompt_tokens = length(Tokens)}, hibernate};
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
    S2 = S1#st{slot = Slot},
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
%% the matching comment in erllama_server_h_chat).
%% erllama 0.3.0 carries extended-thinking deltas inside the same
%% `erllama_token` tag using a {thinking_delta, Bin} payload (the
%% engine's `thinking => enabled` Params hook); plain binary payloads
%% are text fragments.
info({erllama_token, Ref, {thinking_delta, Bin}}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Bin, Req, S);
info({erllama_token, Ref, Tok}, Req0, S0) when is_binary(Tok) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_token(Tok, Req, S);
%% Legacy reasoning-token tag for backends that emit reasoning out of
%% band; harmless if never fired.
info({erllama_reasoning_token, Ref, Tok}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_reasoning(Tok, Req, S);
%% erllama 0.3.0 emits exactly one close marker per thinking block,
%% carrying an opaque integrity signature. The Anthropic spec requires
%% a `signature_delta` SSE event before the matching `content_block_stop`.
info({erllama_thinking_end, Ref, Sig}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    handle_thinking_end(Sig, Req, S);
info({erllama_done, Ref, Stats}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_ok(Req, S, Stats);
info({erllama_error, Ref, Reason}, Req0, S0) ->
    {S, Req} = learn_ref(S0, Req0, Ref),
    finish_err(Req, S, Reason);
info({prefill_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    erllama:cancel(Ref),
    finish_err(Req, S, prefill_timeout);
info({idle_timeout, Ref}, Req, S = #st{ref = Ref}) ->
    erllama:cancel(Ref),
    finish_err(Req, S, generation_idle_timeout);
info({gen_ping, Ref}, Req, S = #st{ref = Ref, stream_started = true}) ->
    %% Cadence keepalive while generation is active. Re-arm and emit
    %% only when the stream is open; ignore stale messages.
    ok = anthropic_ping(Req),
    {ok, Req, arm_gen_ping(S), hibernate};
info({gen_ping, _}, Req, S) ->
    {ok, Req, S, hibernate};
info(total_request_timeout, Req, S = #st{phase = running, ref = Ref}) when is_reference(Ref) ->
    erllama:cancel(Ref),
    finish_err(Req, S, total_timeout);
info(total_request_timeout, Req0, S) ->
    Req1 = json_error(504, total_timeout, Req0),
    record_metrics(S, 504),
    {stop, Req1, S};
%% erllama 0.2.0 emits a token-id message alongside every token text
%% message. We do not consume it.
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
    cancel_timer(S#st.gen_ping_tref),
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
    keepalive_release(S#st.model, S#st.phase),
    erllama_server_metrics:dec_active_streams(S#st.model).

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
    S1 = ensure_text_block_started(Req, S),
    Iolist = erllama_server_translate:internal_to_anthropic_event(
        {text_delta, Tok, S1#st.text_block_started}, #{}, S#st.req_id, S#st.requested
    ),
    cowboy_req:stream_body(Iolist, nofin, Req),
    {ok, Req, rearm_idle(S1#st{out_tokens = S1#st.out_tokens + 1}), hibernate};
emit_text(Tok, Req, S = #st{stream = false}) ->
    {ok, Req,
        rearm_idle(S#st{
            buf_text = [S#st.buf_text, Tok],
            out_tokens = S#st.out_tokens + 1
        }), hibernate}.

%% `thinking_display = omitted` keeps the engine producing thinking
%% but hides it on the wire: no thinking_delta SSE frames, no thinking
%% content block, no signature_delta. The engine still pays the
%% generation cost; only the visible output is suppressed.
handle_reasoning(_Tok, Req, S = #st{thinking_display = omitted}) ->
    {ok, Req, rearm_idle(S), hibernate};
handle_reasoning(Tok, Req, S = #st{stream = true}) ->
    S1 = ensure_thinking_block_started(Req, S),
    Iolist = erllama_server_translate:internal_to_anthropic_event(
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
                    <<"signature">> => Sig
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

%%====================================================================
%% Stream block management
%%====================================================================

emit_message_start(_Req, S = #st{message_started = true}) ->
    S;
emit_message_start(Req, S) ->
    Iolist = erllama_server_translate:internal_to_anthropic_event(
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
    Iolist = erllama_server_translate:internal_to_anthropic_event(
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
    Iolist = erllama_server_translate:internal_to_anthropic_event(
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

finish_ok(Req0, S = #st{stream = true, mode = text}, Stats) ->
    %% Close any open content block at its assigned index, then
    %% message_delta + message_stop.
    OpenIdx = open_block_index(S),
    Req1 =
        case OpenIdx of
            undefined ->
                Req0;
            I ->
                StopBlock = erllama_server_translate:internal_to_anthropic_event(
                    {content_block_stop, I}, #{}, S#st.req_id, S#st.requested
                ),
                cowboy_req:stream_body(StopBlock, nofin, Req0),
                Req0
        end,
    Delta = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(Stats, S)}, #{}, S#st.req_id, S#st.requested
    ),
    Stop = erllama_server_translate:internal_to_anthropic_event(
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
            <<"partial_json">> => json:encode(Input)
        }
    },
    Stop = erllama_server_translate:internal_to_anthropic_event(
        {content_block_stop, Idx}, #{}, S#st.req_id, S#st.requested
    ),
    StatsToolCall = maps:put(finish_reason, tool_call, Stats),
    MsgDelta = erllama_server_translate:internal_to_anthropic_event(
        {message_delta, attach_cache_hints(StatsToolCall, S)},
        #{},
        S#st.req_id,
        S#st.requested
    ),
    MsgStop = erllama_server_translate:internal_to_anthropic_event(
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
    Body = erllama_server_translate:internal_to_anthropic_messages_response(
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
thinking_block(Text, undefined) ->
    #{<<"type">> => <<"thinking">>, <<"thinking">> => Text};
thinking_block(Text, <<>>) ->
    #{<<"type">> => <<"thinking">>, <<"thinking">> => Text};
thinking_block(Text, Sig) when is_binary(Sig) ->
    #{
        <<"type">> => <<"thinking">>,
        <<"thinking">> => Text,
        <<"signature">> => Sig
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
    erllama_server_metrics:observe_prefill(S#st.model, PrefillSec),
    cancel_timer(S#st.prefill_tref),
    rearm_idle(S#st{first_token_at = Now, prefill_tref = undefined});
first_token(S) ->
    rearm_idle(S).

%% See learn_ref/3 in erllama_server_h_chat. For streaming requests
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
        erllama_server_queue:stats(Model),
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
    Seconds = erllama_server_config:anthropic_retry_after_seconds(),
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
    Ms = erllama_server_config:generation_ping_ms(),
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

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

record_success(S, Stats) ->
    record_metrics(S, 200),
    erllama_server_metrics:inc_prompt_tokens(
        S#st.model,
        maps:get(prompt_tokens, Stats, 0)
    ),
    erllama_server_metrics:inc_completion_tokens(
        S#st.model,
        maps:get(completion_tokens, Stats, 0)
    ).

record_error(S, _Reason) -> record_metrics(S, 500).

record_metrics(S, Status) ->
    Now = mono_ms(),
    Duration = (Now - S#st.started_mono) / 1000.0,
    erllama_server_metrics:record_request(
        <<"/v1/messages">>,
        S#st.requested,
        integer_to_binary(Status),
        Duration
    ).

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
    Seconds = erllama_server_config:anthropic_retry_after_seconds(),
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
            <<"message">> => to_bin(Reason)
        }
    },
    case cowboy_req:resp_header(<<"x-request-id">>, Req, undefined) of
        undefined -> Base;
        Id -> Base#{<<"request_id">> => Id}
    end.

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

make_tool_id() ->
    iolist_to_binary([
        <<"toolu_">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
