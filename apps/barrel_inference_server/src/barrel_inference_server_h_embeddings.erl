%%% OpenAI /v1/embeddings.
%%%
%%% Synchronous handler. For each input string, the server tokenises
%%% via the model's tokenizer, then calls barrel_inference:embed/2. v0.1 loops
%%% sequentially; an barrel_inference:embed_batch/2 future call would replace
%%% the loop with a single batched decode. `max_inputs` (default 256)
%%% caps the array length so a single request cannot pin a queue
%%% slot indefinitely.

-module(barrel_inference_server_h_embeddings).

-export([openai/1, ollama/1, ollama_legacy/1]).

openai(Req) -> livery_handle(Req, openai).
ollama(Req) -> livery_handle(Req, ollama).
ollama_legacy(Req) -> livery_handle(Req, ollama_legacy).

livery_handle(Req, Api) ->
    case livery_req:method(Req) of
        <<"POST">> -> livery_post(Req, Api);
        _ -> livery_resp:json(405, json:encode(#{<<"error">> => <<"method_not_allowed">>}))
    end.

livery_post(Req, Api) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Body, _Req1} ->
            case decode(Body) of
                {ok, Map} -> livery_translate(Map, Api);
                error -> livery_error(400, invalid_json, Api)
            end;
        {too_large, _Req1} ->
            livery_error(413, request_too_large, Api)
    end.

livery_translate(Map, Api) ->
    case do_translate(Map, Api) of
        {ok, Parsed = #{model := Requested, inputs := Inputs}} ->
            KeepAlive = maps:get(keep_alive_ms, Parsed, undefined),
            livery_run(Requested, Inputs, Api, KeepAlive);
        {error, Reason} ->
            livery_error(400, Reason, Api)
    end.

livery_run(Requested, Inputs, Api, KeepAlive) ->
    Started = erlang:monotonic_time(millisecond),
    case length(Inputs) > barrel_inference_server_config:max_embedding_inputs() of
        true ->
            livery_error(400, too_many_inputs, Api);
        false ->
            Real = barrel_inference_server_config:resolve_model(Requested),
            case barrel_inference_server_config:ensure_loaded(Real) of
                ok -> livery_do_embed(Real, Requested, Inputs, Started, Api, KeepAlive);
                {error, not_found} -> livery_error(404, model_not_found, Api);
                {error, Reason} -> livery_error(503, Reason, Api)
            end
    end.

livery_do_embed(Real, Requested, Inputs, Started, Api, KeepAlive) ->
    Timeout = queue_timeout(Real),
    case barrel_inference_server_queue:acquire(Real, Timeout) of
        {ok, Slot} ->
            ok = barrel_inference_server_keepalive:request_begin(Real),
            try
                livery_run_embed(Real, Requested, Inputs, Started, Api)
            after
                barrel_inference_server_queue:release(Real, Slot),
                barrel_inference_server_keepalive:request_end(
                    Real, effective_keep_alive(KeepAlive)
                )
            end;
        {error, pool_exhausted} ->
            barrel_inference_server_metrics:inc_pool_exhausted(Real),
            record_metrics(api_endpoint(Api), Requested, 429, Started),
            livery_error(429, pool_exhausted, Api);
        {error, queue_timeout} ->
            record_metrics(api_endpoint(Api), Requested, 504, Started),
            livery_error(504, queue_timeout, Api)
    end.

livery_run_embed(Real, Requested, Inputs, Started, Api) ->
    case embed_each(Real, Inputs) of
        {ok, Vectors, PromptTokens} ->
            Body = livery_build_response(Api, Vectors, PromptTokens, Requested, Started),
            record_metrics(api_endpoint(Api), Requested, 200, Started),
            barrel_inference_server_metrics:inc_prompt_tokens(Requested, PromptTokens),
            livery_resp:json(200, Body);
        {error, Reason} ->
            Status = embed_status(Reason),
            record_metrics(api_endpoint(Api), Requested, Status, Started),
            livery_error(Status, Reason, Api)
    end.

livery_build_response(Api, Vectors, PromptTokens, Requested, Started) ->
    build_embed_body(Api, Vectors, PromptTokens, Requested, Started).

livery_error(Status, Reason, _Api) ->
    Body = openai_error(
        reason_message(Reason),
        error_type(Status),
        reason_code(Reason)
    ),
    livery_resp:json(Status, json:encode(Body)).

do_translate(Map, openai) ->
    barrel_inference_server_translate:openai_embeddings_to_internal(Map);
do_translate(Map, ollama) ->
    barrel_inference_server_translate:ollama_embed_to_internal(Map);
do_translate(Map, ollama_legacy) ->
    barrel_inference_server_translate:ollama_embeddings_legacy_to_internal(Map).

api_endpoint(ollama) -> <<"/api/embed">>;
api_endpoint(ollama_legacy) -> <<"/api/embeddings">>;
api_endpoint(_) -> <<"/v1/embeddings">>.

build_embed_body(Api, Vectors, PromptTokens, Requested, Started) ->
    Now = erlang:monotonic_time(millisecond),
    Timings = #{
        total_duration_ns => (Now - Started) * 1_000_000,
        load_duration_ns => 0
    },
    case Api of
        ollama ->
            barrel_inference_server_translate:internal_to_ollama_embed_response(
                Requested, Vectors, PromptTokens, Timings
            );
        ollama_legacy ->
            [Vec | _] = Vectors,
            barrel_inference_server_translate:internal_to_ollama_embeddings_legacy_response(
                Requested, Vec, Timings
            );
        _ ->
            json:encode(
                barrel_inference_server_translate:internal_to_openai_embedding_response(
                    Vectors, PromptTokens, Requested
                )
            )
    end.

effective_keep_alive(undefined) -> barrel_inference_server_config:keep_alive_default_ms();
effective_keep_alive(V) -> V.

queue_timeout(Model) ->
    case barrel_inference_server_config:pool_policy_for(Model) of
        immediate_429 ->
            0;
        {queue, #{timeout_ms := T}} ->
            T
    end.

embed_each(Real, Inputs) ->
    embed_each(Real, Inputs, [], 0).
embed_each(_Real, [], Vectors, PromptTokens) ->
    {ok, lists:reverse(Vectors), PromptTokens};
embed_each(Real, [Text | Rest], Vectors, PromptTokens) ->
    case call_model(fun() -> barrel_inference:tokenize(Real, Text) end) of
        {ok, Tokens} ->
            case call_model(fun() -> barrel_inference:embed(Real, Tokens) end) of
                {ok, Vec} ->
                    embed_each(
                        Real,
                        Rest,
                        [Vec | Vectors],
                        PromptTokens + length(Tokens)
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Wrap barrel_inference gen_statem calls so an evicted/crashed model surfaces
%% as a clean {error, not_loaded} instead of exiting the cowboy
%% request process. Without this the noproc exit from
%% barrel_inference_model:via/1 escapes the handler and Ranch reports a
%% torn stream.
call_model(F) ->
    try F() of
        Result -> Result
    catch
        exit:{noproc, {barrel_inference_model, not_found, _}} -> {error, not_loaded};
        exit:{noproc, _} -> {error, not_loaded};
        Class:Why -> {error, {Class, Why}}
    end.

embed_status({error, not_supported}) -> 501;
embed_status(not_supported) -> 501;
embed_status({error, not_loaded}) -> 503;
embed_status(_) -> 500.

%%====================================================================
%% Helpers
%%====================================================================

decode(Body) ->
    try
        case json:decode(Body) of
            Map when is_map(Map) -> {ok, Map};
            _ -> error
        end
    catch
        _:_ -> error
    end.

reason_message(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason_message(Reason) when is_binary(Reason) -> Reason;
reason_message(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

reason_code(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason_code(_) -> <<"server_error">>.

error_type(400) -> <<"invalid_request_error">>;
error_type(404) -> <<"invalid_request_error">>;
error_type(429) -> <<"rate_limit_error">>;
error_type(503) -> <<"server_error">>;
error_type(_) -> <<"server_error">>.

openai_error(Message, Type, Code) ->
    #{
        <<"error">> => #{
            <<"message">> => Message,
            <<"type">> => Type,
            <<"code">> => Code
        }
    }.

record_metrics(Endpoint, Model, Status, StartedMs) ->
    Now = erlang:monotonic_time(millisecond),
    Duration = (Now - StartedMs) / 1000.0,
    barrel_inference_server_metrics:record_request(
        Endpoint, Model, integer_to_binary(Status), Duration
    ).
