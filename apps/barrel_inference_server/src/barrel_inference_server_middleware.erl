%%% Cowboy middleware that runs before any handler.
%%%
%%% Two responsibilities:
%%%
%%%  1. CORS. If `cors` is configured, every response carries the
%%%     `Access-Control-Allow-*` headers and OPTIONS preflights are
%%%     short-circuited with a 204.
%%%
%%%  2. Request id. If the configured request-id header is present
%%%     on the request, its value is echoed back on the response.
%%%     Otherwise the middleware mints a new id and echoes that.
%%%
%%% Both behaviours are no-ops when the corresponding config is off.

-module(barrel_inference_server_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

-define(DEFAULT_ALLOW_HEADERS, <<
    "authorization, content-type, accept, x-request-id, "
    "anthropic-version, anthropic-beta, openai-beta"
>>).
-define(DEFAULT_ALLOW_METHODS,
    <<"GET, POST, OPTIONS">>
).

execute(Req0, Env) ->
    Req1 = handle_request_id(Req0),
    case barrel_inference_server_config:cors() of
        off ->
            {ok, Req1, Env};
        CorsCfg ->
            handle_cors(CorsCfg, Req1, Env)
    end.

%%====================================================================
%% Request id
%%====================================================================

handle_request_id(Req0) ->
    HeaderName = barrel_inference_server_config:request_id_header(),
    Id =
        case cowboy_req:header(HeaderName, Req0, undefined) of
            undefined -> mint_request_id();
            <<>> -> mint_request_id();
            Existing -> Existing
        end,
    cowboy_req:set_resp_header(HeaderName, Id, Req0).

mint_request_id() ->
    Int = erlang:unique_integer([positive]),
    iolist_to_binary([<<"req_">>, integer_to_binary(Int)]).

%%====================================================================
%% CORS
%%====================================================================

handle_cors(CorsCfg, Req0, Env) ->
    case cowboy_req:header(<<"origin">>, Req0, undefined) of
        undefined ->
            {ok, Req0, Env};
        Origin ->
            apply_cors(Origin, CorsCfg, Req0, Env)
    end.

apply_cors(Origin, CorsCfg, Req0, Env) ->
    AllowOrigin = pick_origin(Origin, CorsCfg),
    Headers = #{
        <<"access-control-allow-origin">> => AllowOrigin,
        <<"access-control-allow-credentials">> => allow_creds(CorsCfg),
        <<"access-control-allow-methods">> => allow_methods(CorsCfg),
        <<"access-control-allow-headers">> => allow_headers(CorsCfg),
        <<"access-control-max-age">> => max_age(CorsCfg),
        <<"vary">> => <<"Origin">>
    },
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    case cowboy_req:method(Req1) of
        <<"OPTIONS">> ->
            Req2 = cowboy_req:reply(204, #{}, <<>>, Req1),
            {stop, Req2};
        _ ->
            {ok, Req1, Env}
    end.

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
