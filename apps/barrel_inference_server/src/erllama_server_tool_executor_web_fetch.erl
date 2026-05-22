%%% Server-side `web_fetch' built-in tool executor.
%%%
%%% Fetches a single model-supplied URL and returns its readable text,
%%% so the agentic continue-loop can ground on a specific page (the
%%% natural companion to `web_search'). Registered (disabled by
%%% default) via `builtin_tool_executors':
%%%
%%%   <<"web_fetch">> => #{module => erllama_server_tool_executor_web_fetch,
%%%                        type => <<"web_fetch">>}
%%%
%%% Because the URL is model-controlled, this is an SSRF vector and is
%%% hardened accordingly:
%%%   - only http/https schemes,
%%%   - hosts resolving to loopback/private/link-local addresses are
%%%     rejected unless `allow_private => true' is set in the config,
%%%   - TLS certificates are verified (verify_peer),
%%%   - the response body and the extracted text are size-capped so a
%%%     huge page can't blow the context window or exhaust memory.
-module(erllama_server_tool_executor_web_fetch).
-behaviour(erllama_server_tool_executor).

-include("erllama_server.hrl").

-export([declare/0, execute/2, html_to_text/1, blocked_address/1]).

-define(DEFAULT_MAX_CHARS, 4000).
-define(DEFAULT_TIMEOUT_MS, 10000).
-define(DEFAULT_MAX_BODY, 5 * 1024 * 1024).

declare() ->
    #{
        name => <<"web_fetch">>,
        description =>
            <<"Fetch a URL and return its readable text content.">>,
        schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"url">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The absolute http(s) URL to fetch.">>
                }
            },
            <<"required">> => [<<"url">>]
        }
    }.

execute(#{<<"url">> := Url}, Ctx) when is_binary(Url), Url =/= <<>> ->
    Config = maps:get(config, Ctx, #{}),
    case check_url(Url, Config) of
        ok -> fetch(Url, Config);
        {error, _} = E -> E
    end;
execute(_Args, _Ctx) ->
    {error, missing_url}.

%%====================================================================
%% SSRF guard
%%====================================================================

%% http/https only, and the host must not resolve to a private,
%% loopback, or link-local address (unless `allow_private').
check_url(Url, Config) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} when Host =/= <<>> ->
            check_scheme_host(string:lowercase(Scheme), Host, Config);
        _ ->
            {error, invalid_url}
    end.

check_scheme_host(Scheme, _Host, _Config) when Scheme =/= <<"http">>, Scheme =/= <<"https">> ->
    {error, {unsupported_scheme, Scheme}};
check_scheme_host(_Scheme, Host, Config) ->
    case maps:get(allow_private, Config, false) of
        true -> ok;
        _ -> check_host_addresses(Host)
    end.

check_host_addresses(Host) ->
    HostStr = binary_to_list(Host),
    Addrs = resolve(HostStr, inet) ++ resolve(HostStr, inet6),
    case Addrs of
        [] ->
            %% Unresolvable here; let hackney fail the connect. Don't
            %% block (could be a transient resolver issue), but a
            %% literal private IP is still caught below via resolve/2
            %% returning the parsed address.
            ok;
        _ ->
            case lists:any(fun blocked_address/1, Addrs) of
                true -> {error, blocked_host};
                false -> ok
            end
    end.

resolve(HostStr, Family) ->
    case inet:getaddr(HostStr, Family) of
        {ok, Addr} -> [Addr];
        {error, _} -> []
    end.

%% Loopback / private / link-local / unspecified ranges, v4 and v6.
blocked_address({127, _, _, _}) -> true;
blocked_address({10, _, _, _}) -> true;
blocked_address({192, 168, _, _}) -> true;
blocked_address({169, 254, _, _}) -> true;
blocked_address({0, _, _, _}) -> true;
blocked_address({172, B, _, _}) when B >= 16, B =< 31 -> true;
blocked_address({100, B, _, _}) when B >= 64, B =< 127 -> true;
blocked_address({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
blocked_address({16#fe80, _, _, _, _, _, _, _}) -> true;
blocked_address({W, _, _, _, _, _, _, _}) when W >= 16#fc00, W =< 16#fdff -> true;
blocked_address(_) -> false.

%%====================================================================
%% Fetch
%%====================================================================

fetch(Url, Config) ->
    Timeout = maps:get(timeout_ms, Config, ?DEFAULT_TIMEOUT_MS),
    Opts = [
        with_body,
        {recv_timeout, Timeout},
        {connect_timeout, Timeout},
        {max_body, maps:get(max_body, Config, ?DEFAULT_MAX_BODY)},
        {ssl_options, tls_opts()}
    ],
    case hackney:request(get, Url, [], <<>>, Opts) of
        {ok, 200, Headers, Body} ->
            {ok, #{
                <<"url">> => Url,
                <<"content">> => extract(Headers, Body, Config)
            }};
        {ok, Status, _Headers, _Body} ->
            {error, {http_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Verify the server certificate against the OS trust store, with
%% hostname checking. Avoids a MITM on the fetched URL.
tls_opts() ->
    [
        {verify, verify_peer},
        {depth, 10},
        {cacerts, public_key:cacerts_get()},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

extract(Headers, Body, Config) ->
    Text =
        case is_html(Headers) of
            true -> html_to_text(Body);
            false -> Body
        end,
    truncate(Text, maps:get(max_chars, Config, ?DEFAULT_MAX_CHARS)).

is_html(Headers) ->
    case lists:keyfind(<<"content-type">>, 1, normalise_headers(Headers)) of
        {_, CT} -> binary:match(string:lowercase(CT), <<"html">>) =/= nomatch;
        false -> false
    end.

normalise_headers(Headers) ->
    [{string:lowercase(K), V} || {K, V} <- Headers].

truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) -> <<(binary:part(Bin, 0, Max))/binary, "...">>.

%% Naive but dependency-free HTML -> text: drop script/style bodies,
%% strip tags, decode a few common entities, collapse whitespace.
html_to_text(Html) ->
    NoScript = re:replace(
        Html,
        "<(script|style)[^>]*>.*?</\\1>",
        " ",
        [global, caseless, dotall, {return, binary}]
    ),
    NoTags = re:replace(NoScript, "<[^>]+>", " ", [global, {return, binary}]),
    Decoded = decode_entities(NoTags),
    Collapsed = re:replace(Decoded, "\\s+", " ", [global, {return, binary}]),
    string:trim(Collapsed).

decode_entities(Bin) ->
    lists:foldl(
        fun({From, To}, Acc) ->
            binary:replace(Acc, From, To, [global])
        end,
        Bin,
        [
            {<<"&nbsp;">>, <<" ">>},
            {<<"&amp;">>, <<"&">>},
            {<<"&lt;">>, <<"<">>},
            {<<"&gt;">>, <<">">>},
            {<<"&quot;">>, <<"\"">>},
            {<<"&#39;">>, <<"'">>}
        ]
    ).
