%%% OpenAI /v1/embeddings.
%%%
%%% Synchronous handler. For each input string, the server tokenises
%%% via the model's tokenizer, then calls erllama:embed/2. v0.1 loops
%%% sequentially; an erllama:embed_batch/2 future call would replace
%%% the loop with a single batched decode. `max_inputs` (default 256)
%%% caps the array length so a single request cannot pin a queue
%%% slot indefinitely.

-module(erllama_server_h_embeddings).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, Opts) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, Opts);
        _ -> {ok, cowboy_req:reply(405, #{}, <<>>, Req0), Opts}
    end.

handle_post(Req0, Opts) ->
    MaxBody = erllama_server_config:max_request_body_bytes(),
    case cowboy_req:read_body(Req0, #{length => MaxBody}) of
        {ok, Body, Req1} -> dispatch(Body, Req1, Opts);
        {more, _, Req1} -> reply_error(413, request_too_large, Req1, Opts)
    end.

dispatch(Body, Req0, Opts) ->
    case decode(Body) of
        {ok, Map} -> translate(Map, Req0, Opts);
        error -> reply_error(400, invalid_json, Req0, Opts)
    end.

translate(Map, Req0, Opts) ->
    case erllama_server_translate:openai_embeddings_to_internal(Map) of
        {ok, #{model := Requested, inputs := Inputs}} ->
            run(Requested, Inputs, Req0, Opts);
        {error, Reason} ->
            reply_error(400, Reason, Req0, Opts)
    end.

run(Requested, Inputs, Req0, Opts) ->
    Started = erlang:monotonic_time(millisecond),
    case length(Inputs) > erllama_server_config:max_embedding_inputs() of
        true ->
            reply_error(400, too_many_inputs, Req0, Opts);
        false ->
            Real = erllama_server_config:resolve_model(Requested),
            case erllama_server_config:ensure_loaded(Real) of
                ok ->
                    do_embed(Real, Requested, Inputs, Started, Req0, Opts);
                {error, not_found} ->
                    reply_error(404, model_not_found, Req0, Opts);
                {error, Reason} ->
                    reply_error(503, Reason, Req0, Opts)
            end
    end.

do_embed(Real, Requested, Inputs, Started, Req0, Opts) ->
    Timeout = queue_timeout(Real),
    case erllama_server_queue:acquire(Real, Timeout) of
        {ok, Slot} ->
            try
                run_embed(Real, Requested, Inputs, Started, Req0, Opts)
            after
                erllama_server_queue:release(Real, Slot)
            end;
        {error, pool_exhausted} ->
            erllama_server_metrics:inc_pool_exhausted(Real),
            record_metrics(<<"/v1/embeddings">>, Requested, 429, Started),
            reply_error(429, pool_exhausted, Req0, Opts);
        {error, queue_timeout} ->
            record_metrics(<<"/v1/embeddings">>, Requested, 504, Started),
            reply_error(504, queue_timeout, Req0, Opts)
    end.

run_embed(Real, Requested, Inputs, Started, Req0, Opts) ->
    case embed_each(Real, Inputs) of
        {ok, Vectors, PromptTokens} ->
            Body = erllama_server_translate:internal_to_openai_embedding_response(
                Vectors, PromptTokens, Requested
            ),
            Encoded = json:encode(Body),
            Req1 = cowboy_req:reply(
                200,
                #{<<"content-type">> => <<"application/json">>},
                Encoded,
                Req0
            ),
            record_metrics(<<"/v1/embeddings">>, Requested, 200, Started),
            erllama_server_metrics:inc_prompt_tokens(Requested, PromptTokens),
            {ok, Req1, Opts};
        {error, Reason} ->
            Status = embed_status(Reason),
            record_metrics(<<"/v1/embeddings">>, Requested, Status, Started),
            reply_error(Status, Reason, Req0, Opts)
    end.

queue_timeout(Model) ->
    case erllama_server_config:pool_policy_for(Model) of
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
    case erllama:tokenize(Real, Text) of
        {ok, Tokens} ->
            case erllama:embed(Real, Tokens) of
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

embed_status({error, not_supported}) -> 501;
embed_status(not_supported) -> 501;
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

reply_error(Status, Reason, Req0, Opts) ->
    Body = openai_error(
        reason_message(Reason),
        error_type(Status),
        reason_code(Reason)
    ),
    Req1 = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    {ok, Req1, Opts}.

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
    erllama_server_metrics:record_request(
        Endpoint, Model, integer_to_binary(Status), Duration
    ).
