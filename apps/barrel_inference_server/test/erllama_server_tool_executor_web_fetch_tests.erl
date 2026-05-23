%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(erllama_server_tool_executor_web_fetch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, erllama_server_tool_executor_web_fetch).

declare_shape_test() ->
    Tool = ?M:declare(),
    ?assertEqual(<<"web_fetch">>, maps:get(name, Tool)),
    Schema = maps:get(schema, Tool),
    ?assertEqual([<<"url">>], maps:get(<<"required">>, Schema)).

missing_url_test() ->
    ?assertEqual({error, missing_url}, ?M:execute(#{}, #{})),
    ?assertEqual({error, missing_url}, ?M:execute(#{<<"url">> => <<>>}, #{})).

unsupported_scheme_test() ->
    ?assertEqual(
        {error, {unsupported_scheme, <<"ftp">>}},
        ?M:execute(#{<<"url">> => <<"ftp://example.com/x">>}, #{})
    ),
    %% file:// with a host is rejected as an unsupported scheme; the
    %% hostless form below falls to invalid_url - either way, blocked.
    ?assertEqual(
        {error, {unsupported_scheme, <<"file">>}},
        ?M:execute(#{<<"url">> => <<"file://host/etc/passwd">>}, #{})
    ),
    ?assertEqual(
        {error, invalid_url},
        ?M:execute(#{<<"url">> => <<"file:///etc/passwd">>}, #{})
    ).

invalid_url_test() ->
    ?assertEqual(
        {error, invalid_url},
        ?M:execute(#{<<"url">> => <<"not a url">>}, #{})
    ).

%% SSRF: model-supplied URLs that resolve to loopback / link-local /
%% private addresses are rejected before any fetch.
blocks_loopback_test() ->
    ?assertEqual(
        {error, blocked_host},
        ?M:execute(#{<<"url">> => <<"http://127.0.0.1:9/x">>}, #{})
    ).

blocks_cloud_metadata_test() ->
    ?assertEqual(
        {error, blocked_host},
        ?M:execute(#{<<"url">> => <<"http://169.254.169.254/latest/meta-data/">>}, #{})
    ).

blocks_localhost_test() ->
    ?assertEqual(
        {error, blocked_host},
        ?M:execute(#{<<"url">> => <<"http://localhost/admin">>}, #{})
    ).

blocked_address_predicate_test() ->
    ?assert(?M:blocked_address({127, 0, 0, 1})),
    ?assert(?M:blocked_address({10, 0, 0, 5})),
    ?assert(?M:blocked_address({192, 168, 1, 1})),
    ?assert(?M:blocked_address({169, 254, 169, 254})),
    ?assert(?M:blocked_address({172, 16, 0, 1})),
    ?assert(?M:blocked_address({172, 31, 255, 255})),
    ?assert(?M:blocked_address({0, 0, 0, 0, 0, 0, 0, 1})),
    %% public addresses pass
    ?assertNot(?M:blocked_address({8, 8, 8, 8})),
    ?assertNot(?M:blocked_address({1, 1, 1, 1})),
    ?assertNot(?M:blocked_address({172, 32, 0, 1})).

html_to_text_test() ->
    Html =
        <<
            "<html><head><style>.a{}</style></head>"
            "<body><script>var x=1;</script>"
            "<h1>Title</h1><p>Hello&nbsp;&amp; world</p></body></html>"
        >>,
    Text = ?M:html_to_text(Html),
    %% script/style bodies dropped, tags stripped, entities decoded
    ?assertEqual(nomatch, binary:match(Text, <<"var x">>)),
    ?assertEqual(nomatch, binary:match(Text, <<".a{}">>)),
    ?assert(binary:match(Text, <<"Title">>) =/= nomatch),
    ?assert(binary:match(Text, <<"Hello & world">>) =/= nomatch).
