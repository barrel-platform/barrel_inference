%%% livery middleware: request-id header echo + mint, honouring the
%%% operator-configurable header name from
%%% `barrel_inference_server_config:request_id_header/0' (livery's
%%% built-in `livery_request_id' hardcodes `x-request-id', which would
%%% break the existing customisable-header contract).

-module(barrel_inference_server_request_id_mw).
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(), term()) ->
    livery_resp:resp().
call(Req, Next, _State) ->
    HeaderName = barrel_inference_server_config:request_id_header(),
    Id =
        case livery_req:header(HeaderName, Req) of
            undefined -> mint();
            <<>> -> mint();
            Existing -> Existing
        end,
    Req1 = livery_req:set_req_id(Id, Req),
    Resp = Next(Req1),
    livery_resp:with_header(HeaderName, Id, Resp).

mint() ->
    Int = erlang:unique_integer([positive]),
    iolist_to_binary([<<"req_">>, integer_to_binary(Int)]).
