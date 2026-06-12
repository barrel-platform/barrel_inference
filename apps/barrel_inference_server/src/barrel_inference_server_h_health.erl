%%% Liveness and readiness probes.
%%%
%%% Routed at:
%%%   GET /health        -> liveness (always 200 if the BEAM is up)
%%%   GET /health/ready  -> readiness (200 only if at least one model
%%%                          is loaded and reported `ready`)

-module(barrel_inference_server_h_health).

%% livery entry points (one per route binding in
%% barrel_inference_server_routes:routes/0).
-export([liveness/1, readiness/1]).

liveness(_Req) ->
    {Status, Body} = probe(liveness),
    livery_resp:json(Status, json:encode(Body)).

readiness(_Req) ->
    {Status, Body} = probe(readiness),
    livery_resp:json(Status, json:encode(Body)).

probe(liveness) ->
    case is_pid(whereis(barrel_inference_server_sup)) of
        true -> {200, #{<<"status">> => <<"ok">>}};
        false -> {503, #{<<"status">> => <<"down">>}}
    end;
probe(readiness) ->
    Models = list_ready_models(),
    case Models of
        [] ->
            {503, #{<<"status">> => <<"not_ready">>, <<"models">> => []}};
        _ ->
            {200, #{<<"status">> => <<"ready">>, <<"models">> => Models}}
    end.

list_ready_models() ->
    try barrel_inference:list_models() of
        Infos when is_list(Infos) ->
            [maps:get(id, I) || I <- Infos, is_ready(maps:get(status, I, undefined))]
    catch
        _:_ -> []
    end.

is_ready(idle) -> true;
is_ready(prefilling) -> true;
is_ready(generating) -> true;
is_ready(_) -> false.
