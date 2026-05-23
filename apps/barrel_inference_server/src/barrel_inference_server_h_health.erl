%%% Liveness and readiness probes.
%%%
%%% Routed at:
%%%   GET /health        -> liveness (always 200 if the BEAM is up)
%%%   GET /health/ready  -> readiness (200 only if at least one model
%%%                          is loaded and reported `ready`)
%%%
%%% Implemented as a plain `cowboy_handler`. The state is taken from
%%% the route opts map (`#{kind => liveness | readiness}`).

-module(barrel_inference_server_h_health).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, #{kind := Kind} = Opts) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            {Status, Body} = probe(Kind),
            Req1 = cowboy_req:reply(
                Status,
                #{<<"content-type">> => <<"application/json">>},
                json:encode(Body),
                Req0
            ),
            {ok, Req1, Opts};
        _ ->
            Req1 = cowboy_req:reply(405, #{}, <<>>, Req0),
            {ok, Req1, Opts}
    end.

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
