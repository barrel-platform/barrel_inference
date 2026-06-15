%%% Hackney-backed compat shim for the CT suites. Mirrors the
%%% `httpc:request/1,2,4` argument shape and return tuple so the
%%% existing test bodies can call `?MODULE:request(...)` without any
%%% other rewriting. Hackney replaces `httpc` everywhere in this
%%% project — see the http-client-preference memory.

-module(barrel_inference_server_http_test).

-export([request/1, request/2, request/4]).
-export([set_options/1, ensure_started/0]).

%% Boot hackney's apps; CT suites call this from init_per_suite where
%% they previously called `application:ensure_all_started(inets)`.
ensure_started() ->
    application:ensure_all_started(hackney).

%% No-op (kept so the call sites don't have to change). httpc had
%% `set_options/1`; hackney's tuning is per-request via Opts.
set_options(_Opts) -> ok.

%% Shape parity with httpc:
%%   request(Url)
%%   request(get, {Url, Headers}, HttpOpts, Opts)
%%   request(post, {Url, Headers, ContentType, Body}, HttpOpts, Opts)
request(Url) ->
    do(get, to_bin(Url), [], <<>>, []).

request(get, {Url, Headers}) ->
    do(get, to_bin(Url), normalise_req_headers(Headers), <<>>, []).

request(Method, {Url, Headers}, HttpOpts, _Opts) ->
    do(Method, to_bin(Url), normalise_req_headers(Headers), <<>>, hackney_opts(HttpOpts));
request(Method, {Url, Headers, ContentType, Body}, HttpOpts, _Opts) ->
    AllHeaders = [
        {<<"content-type">>, to_bin(ContentType)}
        | normalise_req_headers(Headers)
    ],
    do(Method, to_bin(Url), AllHeaders, to_bin(Body), hackney_opts(HttpOpts)).

%% --- internals ---

do(Method, Url, Headers, Body, Opts) ->
    case hackney:request(Method, Url, Headers, Body, [with_body | Opts]) of
        {ok, Status, RespHeaders, RespBody} ->
            HeaderList = [
                {string:to_lower(binary_to_list(K)), binary_to_list(V)}
             || {K, V} <- RespHeaders
            ],
            {ok, {{"HTTP/1.1", Status, ""}, HeaderList, binary_to_list(RespBody)}};
        {error, _} = E ->
            E
    end.

normalise_req_headers(L) ->
    [{to_bin(K), to_bin(V)} || {K, V} <- L].

hackney_opts(HttpOpts) ->
    %% Translate the few httpc options the suites pass.
    lists:flatmap(
        fun
            ({timeout, T}) -> [{recv_timeout, T}, {connect_timeout, T}];
            ({connect_timeout, T}) -> [{connect_timeout, T}];
            (_) -> []
        end,
        HttpOpts
    ).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
