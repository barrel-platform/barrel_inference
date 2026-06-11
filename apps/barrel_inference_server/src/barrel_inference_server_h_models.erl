%%% OpenAI-compatible /v1/models[/:model_id] endpoint.
%%%
%%%   GET /v1/models           -> {"object":"list","data":[...]}
%%%   GET /v1/models/:model_id -> single model object or 404
%%%
%%% Aliases configured via barrel_inference_server_config are surfaced as
%%% separate entries (id = alias, owned_by = "barrel_inference-alias") so
%%% OpenAI clients can pick by alias and see what is available.

-module(barrel_inference_server_h_models).
-behaviour(cowboy_handler).

-export([init/2]).

%% livery entry points.
-export([list/1, single/1]).

list(_Req) ->
    {200, Body} = list_response(),
    livery_resp:json(200, json:encode(Body)).

single(Req) ->
    ModelId = livery_req:binding(<<"model_id">>, Req),
    {Status, Body} = single_response(ModelId),
    livery_resp:json(Status, json:encode(Body)).

init(Req0, Opts) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            handle_get(Req0, Opts);
        _ ->
            {ok, cowboy_req:reply(405, #{}, <<>>, Req0), Opts}
    end.

handle_get(Req0, Opts) ->
    case cowboy_req:binding(model_id, Req0) of
        undefined ->
            list(Req0, Opts);
        ModelId ->
            single(ModelId, Req0, Opts)
    end.

list(Req0, Opts) ->
    {Status, Body} = list_response(),
    Req1 = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    {ok, Req1, Opts}.

single(ModelId, Req0, Opts) ->
    {Status, Body} = single_response(ModelId),
    Req1 = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Body),
        Req0
    ),
    {ok, Req1, Opts}.

%%====================================================================
%% Internal
%%====================================================================

list_response() ->
    Now = erlang:system_time(second),
    Loaded = [model_entry(I, Now, <<"barrel_inference">>) || I <- safe_list_models()],
    Aliases = alias_entries(Now),
    Body = #{
        <<"object">> => <<"list">>,
        <<"data">> => Loaded ++ Aliases
    },
    {200, Body}.

single_response(ModelId) ->
    Resolved = barrel_inference_server_config:resolve_model(ModelId),
    case lookup(Resolved) of
        {ok, Info} ->
            Body = model_entry(Info, erlang:system_time(second), <<"barrel_inference">>),
            {200, Body};
        not_found ->
            Body = openai_error(
                <<"model not found">>,
                <<"invalid_request_error">>,
                <<"model_not_found">>
            ),
            {404, Body}
    end.

safe_list_models() ->
    try barrel_inference:list_models() of
        L when is_list(L) -> L
    catch
        _:_ -> []
    end.

lookup(ModelId) ->
    Loaded = safe_list_models(),
    case [I || I <- Loaded, maps:get(id, I, undefined) =:= ModelId] of
        [Info] -> {ok, Info};
        _ -> not_found
    end.

model_entry(Info, Now, OwnedBy) ->
    #{
        <<"id">> => maps:get(id, Info, <<>>),
        <<"object">> => <<"model">>,
        <<"created">> => Now,
        <<"owned_by">> => OwnedBy
    }.

alias_entries(Now) ->
    Map = persistent_term:get({barrel_inference_server_config, aliases}, #{}),
    [
        #{
            <<"id">> => Alias,
            <<"object">> => <<"model">>,
            <<"created">> => Now,
            <<"owned_by">> => <<"barrel_inference-alias">>
        }
     || Alias <- maps:keys(Map)
    ].

openai_error(Message, Type, Code) ->
    #{
        <<"error">> => #{
            <<"message">> => Message,
            <<"type">> => Type,
            <<"code">> => Code
        }
    }.
