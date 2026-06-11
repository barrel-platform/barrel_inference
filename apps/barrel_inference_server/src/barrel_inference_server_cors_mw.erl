%%% livery middleware: CORS, adapter to our config shape.
%%%
%%% Mirrors the behaviour of the cowboy-side `barrel_inference_server_middleware'
%%% so the migration is observably identical: no Origin -> pass through;
%%% Origin + OPTIONS preflight -> 204 with allow headers; Origin + other
%%% method -> stamp allow headers on the response.
%%%
%%% `off' short-circuits to a plain pass-through.

-module(barrel_inference_server_cors_mw).
-behaviour(livery_middleware).

-export([call/3]).

-define(DEFAULT_ALLOW_HEADERS, <<
    "authorization, content-type, accept, x-request-id, "
    "anthropic-version, anthropic-beta, openai-beta"
>>).
-define(DEFAULT_ALLOW_METHODS,
    <<"GET, POST, OPTIONS">>
).

-spec call(livery_req:req(), livery_middleware:next(), term()) ->
    livery_resp:resp().
call(Req, Next, _State) ->
    case barrel_inference_server_config:cors() of
        off ->
            Next(Req);
        CorsCfg ->
            handle_cors(CorsCfg, Req, Next)
    end.

handle_cors(CorsCfg, Req, Next) ->
    case livery_req:header(<<"origin">>, Req) of
        undefined ->
            Next(Req);
        Origin ->
            apply_cors(Origin, CorsCfg, Req, Next)
    end.

apply_cors(Origin, CorsCfg, Req, Next) ->
    AllowOrigin = pick_origin(Origin, CorsCfg),
    Headers = [
        {<<"access-control-allow-origin">>, AllowOrigin},
        {<<"access-control-allow-credentials">>, allow_creds(CorsCfg)},
        {<<"access-control-allow-methods">>, allow_methods(CorsCfg)},
        {<<"access-control-allow-headers">>, allow_headers(CorsCfg)},
        {<<"access-control-max-age">>, max_age(CorsCfg)},
        {<<"vary">>, <<"Origin">>}
    ],
    case livery_req:method(Req) of
        <<"OPTIONS">> ->
            apply_headers(Headers, livery_resp:empty(204));
        _ ->
            apply_headers(Headers, Next(Req))
    end.

apply_headers([], Resp) ->
    Resp;
apply_headers([{Name, Value} | Rest], Resp) ->
    apply_headers(Rest, livery_resp:with_header(Name, Value, Resp)).

pick_origin(Origin, #{allow_origins := Allowed}) when is_list(Allowed) ->
    case lists:member(Origin, Allowed) orelse lists:member(<<"*">>, Allowed) of
        true -> Origin;
        false -> <<"null">>
    end;
pick_origin(_Origin, #{allow_origins := <<"*">>}) ->
    <<"*">>;
pick_origin(Origin, _) ->
    Origin.

allow_creds(#{allow_credentials := true}) -> <<"true">>;
allow_creds(#{allow_credentials := false}) -> <<"false">>;
allow_creds(_) -> <<"false">>.

allow_methods(#{allow_methods := M}) when is_binary(M) -> M;
allow_methods(_) -> ?DEFAULT_ALLOW_METHODS.

allow_headers(#{allow_headers := H}) when is_binary(H) -> H;
allow_headers(_) -> ?DEFAULT_ALLOW_HEADERS.

max_age(#{max_age := N}) when is_integer(N), N > 0 ->
    integer_to_binary(N);
max_age(_) ->
    <<"600">>.
