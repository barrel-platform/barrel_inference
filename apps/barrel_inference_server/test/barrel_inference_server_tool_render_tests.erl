%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% Unit tests for the native tool-prompt rendering (the per-family
%% render_prompt/2 callbacks) and the request-level native_turn/1 gate.
%% The positive native_turn path (a marker model resolves to its render
%% module) reads a manifest from disk and is covered by the live
%% verification; here we cover the pure render output and every gate
%% short-circuit.
-module(barrel_inference_server_tool_render_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_inference_server.hrl").

tools() ->
    [
        #{
            name => <<"get_weather">>,
            description => <<"Look up the weather for a city">>,
            schema => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}},
                <<"required">> => [<<"city">>]
            }
        }
    ].

%% =============================================================================
%% render_prompt/2 per family
%% =============================================================================

qwen_render_contains_tools_block_and_marker_test() ->
    Out = barrel_inference_server_tool_format_qwen_xml:render_prompt(tools(), undefined),
    ?assert(is_binary(Out)),
    assert_contains(Out, <<"<tools>">>),
    assert_contains(Out, <<"</tools>">>),
    assert_contains(Out, <<"<tool_call>">>),
    %% The full schema (name + a property) must reach the prompt.
    assert_contains(Out, <<"get_weather">>),
    assert_contains(Out, <<"city">>).

dsml_render_uses_special_token_envelope_test() ->
    Out = barrel_inference_server_tool_format_dsml:render_prompt(tools(), undefined),
    assert_contains(Out, <<"<｜tool▁calls▁begin｜>"/utf8>>),
    assert_contains(Out, <<"<｜tool▁call▁begin｜>"/utf8>>),
    assert_contains(Out, <<"<｜tool▁sep｜>"/utf8>>),
    assert_contains(Out, <<"get_weather">>).

llama_render_uses_python_tag_and_parameters_key_test() ->
    Out = barrel_inference_server_tool_format_llama_python_tag:render_prompt(tools(), undefined),
    assert_contains(Out, <<"<|python_tag|>">>),
    %% Llama uses `parameters', not `arguments'.
    assert_contains(Out, <<"\"parameters\"">>),
    assert_contains(Out, <<"get_weather">>).

mistral_render_uses_available_and_tool_calls_tokens_test() ->
    Out = barrel_inference_server_tool_format_mistral_tool_calls:render_prompt(tools(), undefined),
    assert_contains(Out, <<"[AVAILABLE_TOOLS]">>),
    assert_contains(Out, <<"[/AVAILABLE_TOOLS]">>),
    assert_contains(Out, <<"[TOOL_CALLS]">>),
    assert_contains(Out, <<"get_weather">>).

qwen3_coder_render_uses_nested_function_format_test() ->
    Out = barrel_inference_server_tool_format_qwen3_coder:render_prompt(tools(), undefined),
    assert_contains(Out, <<"<tools>">>),
    assert_contains(Out, <<"</tools>">>),
    %% The call-format instruction uses the nested function/parameter tags.
    assert_contains(Out, <<"<function=">>),
    assert_contains(Out, <<"<parameter=">>),
    assert_contains(Out, <<"</tool_call>">>),
    %% The function name + a property reach the prompt.
    assert_contains(Out, <<"get_weather">>),
    assert_contains(Out, <<"city">>).

%% append_system/2: the family block is appended to an existing system
%% prompt with a blank-line separator, and stands alone when there is none.
append_system_preserves_existing_test() ->
    Out = barrel_inference_server_tool_format_qwen_xml:render_prompt(
        tools(), <<"You are helpful.">>
    ),
    assert_contains(Out, <<"You are helpful.">>),
    assert_contains(Out, <<"<tools>">>),
    ?assertMatch({0, _}, binary:match(Out, <<"You are helpful.">>)).

append_system_undefined_starts_with_block_test() ->
    Out = barrel_inference_server_tool_format_qwen_xml:render_prompt(tools(), undefined),
    ?assertMatch({0, _}, binary:match(Out, <<"# Tools">>)).

%% =============================================================================
%% native_turn/1 gate (request-level short-circuits + safe default)
%% =============================================================================

native_turn_none_when_no_tools_test() ->
    R = #barrel_inference_request{model_id = <<"m">>, tools = undefined, tool_choice = auto},
    ?assertEqual(none, barrel_inference_server_tool_format:native_turn(R)).

native_turn_none_when_empty_tools_test() ->
    R = #barrel_inference_request{model_id = <<"m">>, tools = [], tool_choice = auto},
    ?assertEqual(none, barrel_inference_server_tool_format:native_turn(R)).

native_turn_none_when_choice_not_auto_test() ->
    [
        ?assertEqual(
            none,
            barrel_inference_server_tool_format:native_turn(
                #barrel_inference_request{model_id = <<"m">>, tools = tools(), tool_choice = TC}
            )
        )
     || TC <- [none, required, {named, <<"get_weather">>}]
    ].

%% auto + tools but an unknown model id: native_render hits
%% models:get -> not_found -> none. The safe default keeps the grammar.
native_turn_none_when_model_unknown_test() ->
    R = #barrel_inference_request{
        model_id = <<"no-such-model-xyz">>, tools = tools(), tool_choice = auto
    },
    ?assertEqual(none, barrel_inference_server_tool_format:native_turn(R)).

%% =============================================================================
%% build_grammar/1: the non-native paths still install a tool grammar.
%% =============================================================================

build_grammar_installs_for_unknown_model_auto_test() ->
    R = #barrel_inference_request{
        model_id = <<"no-such-model-xyz">>, tools = tools(), tool_choice = auto
    },
    {ok, Bin} = barrel_inference_server_pipeline:build_grammar(R),
    ?assert(is_binary(Bin)),
    ?assert(byte_size(Bin) > 0).

build_grammar_installs_for_required_test() ->
    R = #barrel_inference_request{
        model_id = <<"no-such-model-xyz">>, tools = tools(), tool_choice = required
    },
    {ok, Bin} = barrel_inference_server_pipeline:build_grammar(R),
    ?assert(byte_size(Bin) > 0).

%% =============================================================================
%% Helpers
%% =============================================================================

assert_contains(Haystack, Needle) ->
    ?assertNotEqual(nomatch, binary:match(Haystack, Needle)).
