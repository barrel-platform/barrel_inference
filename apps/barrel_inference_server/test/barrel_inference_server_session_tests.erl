%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../include/barrel_inference_server.hrl").
-include_lib("livery/include/livery.hrl").

%% Build a livery_req shaped just enough for `livery_req:header/3'.
mock_req(Headers) ->
    Proplist = maps:to_list(Headers),
    #livery_req{headers = Proplist}.

base_request() ->
    #barrel_inference_request{
        model_id = <<"my-model">>,
        messages = [#{role => <<"user">>, content => <<"hello">>}],
        prompt = undefined,
        system = undefined,
        tools = undefined,
        tool_choice = auto,
        grammar = undefined,
        max_tokens = 16,
        temperature = 0.7,
        top_p = 1.0,
        top_k = 40,
        min_p = 0.0,
        seed = undefined,
        stop = [],
        stream = false,
        thinking = disabled,
        api = anthropic,
        request_id = <<"req_1">>
    }.

%% =============================================================================
%% Header wins over user_id and prefix hash
%% =============================================================================

header_wins_over_user_id_test() ->
    Req = mock_req(#{<<"x-conversation-id">> => <<"conv-42">>}),
    R = (base_request())#barrel_inference_request{user_id = <<"u-99">>},
    ?assertEqual(<<"conv-42">>, barrel_inference_server_session:derive(Req, R)).

header_trimmed_test() ->
    Req = mock_req(#{<<"x-conversation-id">> => <<"  conv-42  ">>}),
    R = base_request(),
    ?assertEqual(<<"conv-42">>, barrel_inference_server_session:derive(Req, R)).

empty_header_falls_through_test() ->
    Req = mock_req(#{<<"x-conversation-id">> => <<>>}),
    R = (base_request())#barrel_inference_request{user_id = <<"u-7">>},
    ?assertEqual(<<"u-7">>, barrel_inference_server_session:derive(Req, R)).

oversized_header_falls_through_test() ->
    Big = binary:copy(<<"a">>, 300),
    Req = mock_req(#{<<"x-conversation-id">> => Big}),
    R = (base_request())#barrel_inference_request{user_id = <<"u-7">>},
    ?assertEqual(<<"u-7">>, barrel_inference_server_session:derive(Req, R)).

%% =============================================================================
%% user_id fallback
%% =============================================================================

user_id_used_when_no_header_test() ->
    Req = mock_req(#{}),
    R = (base_request())#barrel_inference_request{user_id = <<"u-7">>},
    ?assertEqual(<<"u-7">>, barrel_inference_server_session:derive(Req, R)).

%% =============================================================================
%% Prefix-hash fallback
%% =============================================================================

prefix_hash_used_when_no_header_or_user_id_test() ->
    Req = mock_req(#{}),
    R = base_request(),
    Id = barrel_inference_server_session:derive(Req, R),
    ?assert(is_binary(Id)),
    %% sha256 base64 = 44 chars
    ?assertEqual(44, byte_size(Id)).

prefix_hash_stable_across_calls_test() ->
    Req = mock_req(#{}),
    R = base_request(),
    A = barrel_inference_server_session:derive(Req, R),
    B = barrel_inference_server_session:derive(Req, R),
    ?assertEqual(A, B).

prefix_hash_changes_with_model_test() ->
    Req = mock_req(#{}),
    R1 = base_request(),
    R2 = R1#barrel_inference_request{model_id = <<"other-model">>},
    ?assertNotEqual(
        barrel_inference_server_session:derive(Req, R1),
        barrel_inference_server_session:derive(Req, R2)
    ).

prefix_hash_changes_with_first_message_test() ->
    Req = mock_req(#{}),
    R1 = base_request(),
    R2 = R1#barrel_inference_request{
        messages = [#{role => <<"user">>, content => <<"different">>}]
    },
    ?assertNotEqual(
        barrel_inference_server_session:derive(Req, R1),
        barrel_inference_server_session:derive(Req, R2)
    ).

prefix_hash_handles_block_list_content_test() ->
    %% Multi-block content (Anthropic style). Should not crash.
    Req = mock_req(#{}),
    Msgs = [#{role => <<"user">>, content => [#{type => <<"text">>, text => <<"x">>}]}],
    R = (base_request())#barrel_inference_request{messages = Msgs},
    Id = barrel_inference_server_session:derive(Req, R),
    ?assertEqual(44, byte_size(Id)).

prefix_hash_handles_empty_messages_test() ->
    Req = mock_req(#{}),
    R = (base_request())#barrel_inference_request{messages = []},
    Id = barrel_inference_server_session:derive(Req, R),
    ?assertEqual(44, byte_size(Id)).
