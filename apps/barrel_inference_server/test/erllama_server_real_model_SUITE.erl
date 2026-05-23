%%% End-to-end CT suite against a real GGUF model. Mirrors erllama's
%%% own `erllama_real_model_SUITE` pattern: gated on `LLAMA_TEST_MODEL`
%%% and skipped when unset, so default `rebar3 ct` stays green
%%% without a model file on disk.
%%%
%%% Usage:
%%%
%%% ```
%%%   LLAMA_TEST_MODEL=/path/to/tinyllama-1.1b-q4_k_m.gguf rebar3 ct \
%%%       --suite=erllama_server_real_model_SUITE
%%% ```
%%%
%%% What it covers:
%%% - /v1/chat/completions streaming + non-streaming
%%% - /v1/messages streaming + non-streaming
%%% - /v1/embeddings (skipped if the model has no chat template OR
%%%   no embedding support)
%%% - /v1/models lists the real model
-module(erllama_server_real_model_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    end_per_testcase/2
]).
-export([
    models_lists_real_model/1,
    load_and_decode_round_trip/1,
    messages_with_many_tools_does_not_crash/1,
    chat_streaming_runs/1,
    chat_non_streaming_runs/1,
    messages_streaming_runs/1,
    messages_non_streaming_runs/1,
    embeddings_runs/1,
    multi_turn_cache_delta_profile/1,
    responses_previous_response_id_continues/1,
    responses_server_tool_loop_runs/1
]).

-define(MODEL_ENV, "LLAMA_TEST_MODEL").
-define(SHORT_PROMPT, <<"The quick brown fox">>).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [
        load_and_decode_round_trip,
        messages_with_many_tools_does_not_crash,
        models_lists_real_model,
        chat_streaming_runs,
        chat_non_streaming_runs,
        messages_streaming_runs,
        messages_non_streaming_runs,
        embeddings_runs,
        multi_turn_cache_delta_profile,
        responses_previous_response_id_continues,
        responses_server_tool_loop_runs
    ].

%%====================================================================
%% Setup
%%====================================================================

init_per_suite(Config) ->
    case os:getenv(?MODEL_ENV) of
        false ->
            {skip, "set " ?MODEL_ENV " to a GGUF path to enable this suite"};
        "" ->
            {skip, "empty " ?MODEL_ENV};
        Path ->
            case filelib:is_regular(Path) of
                false ->
                    {skip, lists:flatten(io_lib:format("not a file: ~ts", [Path]))};
                true ->
                    start_app(Path, Config)
            end
    end.

start_app(Path, Config) ->
    Port = free_port(),
    application:set_env(erllama_server, port, Port),
    application:set_env(erllama_server, model_aliases, #{}),
    application:set_env(
        erllama_server,
        pool_exhausted_policy,
        {queue, #{concurrency => 1, depth => 4, timeout_ms => 60000}}
    ),
    application:set_env(erllama_server, model_load_policy, preloaded),
    application:set_env(erllama_server, prefill_timeout_ms, 120000),
    application:set_env(erllama_server, generation_idle_timeout_ms, 60000),
    application:set_env(erllama_server, max_total_ms, 240000),
    {ok, Started} = application:ensure_all_started(erllama_server),
    {ok, _} = application:ensure_all_started(inets),
    httpc:set_options([
        {max_sessions, 16},
        {max_keep_alive_length, 0},
        {pipeline_timeout, 0}
    ]),
    Dir = make_tmp_dir(),
    DiskSrv = list_to_atom(
        "real_disk_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, DiskSrvPid} = erllama_cache_disk_srv:start_link(DiskSrv, Dir),
    true = unlink(DiskSrvPid),
    ModelId = <<"real">>,
    {ok, _} = erllama:load_model(ModelId, model_config(Path, DiskSrv)),
    [
        {port, Port},
        {base, "http://127.0.0.1:" ++ integer_to_list(Port)},
        {model, ModelId},
        {disk_srv, DiskSrv},
        {dir, Dir},
        {started, Started}
        | Config
    ].

end_per_suite(Config) when is_list(Config) ->
    catch erllama:unload(?config(model, Config)),
    catch gen_server:stop(?config(disk_srv, Config)),
    rm_rf(?config(dir, Config)),
    [application:stop(A) || A <- lists:reverse(?config(started, Config))],
    ok;
end_per_suite(_) ->
    ok.

end_per_testcase(_TC, Config) ->
    Model = ?config(model, Config),
    wait_for_idle(Model, 50),
    ok.

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

make_tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir = filename:join(
        Base,
        "erllama_server_real_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    Dir.

rm_rf(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            [file:delete(filename:join(Dir, E)) || E <- Entries];
        _ ->
            ok
    end,
    file:del_dir(Dir),
    ok.

wait_for_idle(_, 0) ->
    timeout;
wait_for_idle(Model, N) ->
    case catch erllama_model:status(Model) of
        idle ->
            ok;
        _ ->
            timer:sleep(200),
            wait_for_idle(Model, N - 1)
    end.

model_config(Path, DiskSrv) ->
    Fp = file_sha256(Path),
    #{
        backend => erllama_model_llama,
        model_path => Path,
        model_opts => #{n_gpu_layers => 0},
        context_opts => #{n_ctx => 2048, n_batch => 512},
        tier_srv => DiskSrv,
        tier => disk,
        fingerprint => Fp,
        fingerprint_mode => safe,
        quant_type => f16,
        quant_bits => 16,
        ctx_params_hash => crypto:hash(sha256, term_to_binary({2048, 512})),
        context_size => 2048,
        policy => #{
            min_tokens => 16,
            cold_min_tokens => 16,
            cold_max_tokens => 4096,
            continued_interval => 64,
            boundary_trim_tokens => 8,
            boundary_align_tokens => 16,
            session_resume_wait_ms => 1000
        }
    }.

file_sha256(Path) ->
    {ok, Bin} = file:read_file(Path),
    crypto:hash(sha256, Bin).

%%====================================================================
%% Tests
%%====================================================================

%% Regression for the SIGSEGV observed on Apple M4 Pro during Metal
%% device init / first prefill. The model is already loaded in
%% init_per_suite via erllama:load_model/2, so if the load itself
%% crashes the suite errors out at setup. This case then proves the
%% subsequent prefill + a single decode round-trip survives — the
%% exact native paths that died on the user's machine (ggml-metal
%% kernel compile, sched_reserve, first llama_decode). A SIGSEGV in
%% any of those tears down the BEAM and CT records the suite as
%% crashed rather than silently passing.
load_and_decode_round_trip(Cfg) ->
    Model = ?config(model, Cfg),
    %% Sanity: the gen_statem registered by load_model is alive and
    %% addressable. If Metal init segfaulted during load this fails
    %% at the same instant.
    Info = erllama:model_info(Model),
    ?assert(is_map(Info)),
    ?assert(maps:is_key(status, Info)),
    %% Minimal end-to-end: tokenize a short prompt, run prefill via
    %% the inference path, take exactly one generated token. Exercises
    %% the prefill graph + Metal command-queue submission on the M-series
    %% device. Cancel rather than letting it run to completion to keep
    %% the test fast.
    {ok, Tokens} = erllama:tokenize(Model, <<"hi">>),
    ?assert(is_list(Tokens) andalso length(Tokens) > 0),
    Self = self(),
    {ok, Ref} = erllama:infer(
        Model,
        Tokens,
        #{response_tokens => 1, temperature => 0.0},
        Self
    ),
    %% Wait for at least one token OR a clean done — either proves
    %% the native path didn't tip over. Hard 30s timeout caps a
    %% wedged path.
    Outcome =
        receive
            {erllama_token, Ref, _} -> token;
            {erllama_done, Ref, _} -> done;
            {erllama_error, Ref, Reason} -> {error, Reason}
        after 30000 ->
            timeout
        end,
    erllama:cancel(Ref),
    %% Drain any pending messages so subsequent cases start clean.
    drain_inference(Ref, 500),
    ?assert(Outcome =:= token orelse Outcome =:= done).

drain_inference(Ref, BudgetMs) ->
    receive
        {erllama_token, Ref, _} -> drain_inference(Ref, BudgetMs);
        {erllama_done, Ref, _} -> ok;
        {erllama_error, Ref, _} -> ok;
        {erllama_cancelled, Ref} -> ok
    after BudgetMs ->
        ok
    end.

%% Regression for the daemon SIGSEGV when Claude Code points at the
%% server. Mirrors Claude Code's actual request shape: ~30 tools,
%% Anthropic content blocks, system prompt with cache_control. The
%% three paths that minimal load+decode skipped — chat-template
%% render with tools inlined, GBNF compile from a large tools
%% array, prefill with the grammar installed — all run here.
%%
%% A BEAM SIGSEGV in any of those paths tears the cowboy connection
%% before any response is written; httpc returns a transport-level
%% error (`{error, _}`) rather than an HTTP status. The assertion
%% `{ok, {{_, _, _}, ...}}` therefore catches the segfault: a
%% clean 4xx / 5xx still passes (we want to know we did not
%% silently corrupt state), only a torn connection fails.
messages_with_many_tools_does_not_crash(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Tools = [synthetic_tool(I) || I <- lists:seq(1, 30)],
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"system">> => [
            #{
                <<"type">> => <<"text">>,
                <<"text">> => <<"You are a concise assistant.">>,
                <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}
            }
        ],
        <<"tools">> => Tools,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"hi">>}
                ]
            }
        ],
        <<"max_tokens">> => 8,
        <<"stream">> => false
    }),
    Result = httpc:request(
        post, {Url, [], "application/json", Body}, [{timeout, 120000}], []
    ),
    %% Anything other than {ok, {Status, _, _}} means the connection
    %% was torn — almost always a BEAM segfault on the server.
    ?assertMatch({ok, {{_, _, _}, _, _}}, Result),
    {ok, {{_, Status, _}, _, Resp}} = Result,
    %% Pre-fix this case accepted any status >= 400, which masked a
    %% grammar-build regression (llama.cpp's GBNF parser rejecting
    %% rule names with underscores). Tighten to: 200 (real inference)
    %% or 4xx (client error envelope). Anything 5xx means the server
    %% blew up on grammar / chat-template / prefill - the very paths
    %% this case was added to regress against.
    ?assert(Status =:= 200 orelse (Status >= 400 andalso Status < 500)),
    ?assert(byte_size(list_to_binary(Resp)) > 0).

%% A synthetic Anthropic tool with a non-trivial JSON Schema so the
%% GBNF compiler has actual work to do. Keep arg names compact so
%% repeated tools don't blow past llama_n_ctx alone.
synthetic_tool(I) ->
    Name = iolist_to_binary(io_lib:format("tool_~B", [I])),
    #{
        <<"name">> => Name,
        <<"description">> => <<"Synthetic tool ", Name/binary>>,
        <<"input_schema">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"q">> => #{<<"type">> => <<"string">>},
                <<"limit">> => #{<<"type">> => <<"integer">>},
                <<"mode">> => #{
                    <<"type">> => <<"string">>,
                    <<"enum">> => [<<"a">>, <<"b">>, <<"c">>]
                }
            },
            <<"required">> => [<<"q">>]
        }
    }.

models_lists_real_model(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/models",
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Url),
    Decoded = json:decode(list_to_binary(Body)),
    Ids = [maps:get(<<"id">>, M) || M <- maps:get(<<"data">>, Decoded)],
    ?assert(lists:member(<<"real">>, Ids)).

chat_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => true
    }),
    Resp = http_post(Url, Body),
    ?assert(binary:match(Resp, <<"data: [DONE]">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"chat.completion.chunk">>) =/= nomatch),
    %% At least one content chunk must have non-empty content. The
    %% real model produces real text tokens.
    Lines = binary:split(Resp, <<"\n">>, [global]),
    Content = [extract_content(L) || L <- Lines, has_content_delta(L)],
    ?assert(lists:any(fun(B) -> byte_size(B) > 0 end, Content)).

chat_non_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/chat/completions",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(Resp)),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assert(byte_size(maps:get(<<"content">>, Msg)) > 0).

messages_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => true
    }),
    Resp = http_post(Url, Body),
    ?assert(binary:match(Resp, <<"event: message_start">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Resp, <<"event: message_stop">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Resp, <<"data: [DONE]">>)).

messages_non_streaming_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => ?SHORT_PROMPT
            }
        ],
        <<"max_tokens">> => 16,
        <<"stream">> => false
    }),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    Decoded = json:decode(list_to_binary(Resp)),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    [Block] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assert(byte_size(maps:get(<<"text">>, Block)) > 0).

%% Profile: drive a multi-turn /v1/messages conversation through the
%% same session and log the engine's cache_delta evolution across
%% turns. The question this answers: with PR 7b's sticky-seq engine
%% pin live, does the longest-prefix walk on infer/4 already cover
%% the cache reuse we need, or is there leftover prefill on
%% continuation turns where prefill_only/3 could speculatively warm?
%%
%% Output appears in the CT log as a `multi_turn_cache_delta_profile`
%% notice with the per-turn usage map. A useful run shows:
%%
%%   turn 1: cache_read=0, cache_creation=N (cold)
%%   turn 2: cache_read=K, cache_creation=N2-N1
%%   turn 3: cache_read=K', cache_creation=N3-N2
%%
%% If `cache_creation` on turns >= 2 is roughly the new tail length
%% (delta over the prior prompt), the engine already does the right
%% thing on its own and PR 8 has no measurable benefit. If it
%% creates much more than the new tail, prefill_only could amortise
%% the disk restore.
multi_turn_cache_delta_profile(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/messages",
    %% Same x-conversation-id across all three turns so the derived
    %% session_id is stable. Each request adds a new user/assistant
    %% pair to the history.
    ConvId = <<"profile-cache-delta">>,
    Turn1Messages = [
        #{<<"role">> => <<"user">>, <<"content">> => <<"What is 1 + 1?">>}
    ],
    {Usage1, AssistantText1} = profile_turn(Url, ConvId, Turn1Messages),
    Turn2Messages =
        Turn1Messages ++
            [
                #{<<"role">> => <<"assistant">>, <<"content">> => AssistantText1},
                #{<<"role">> => <<"user">>, <<"content">> => <<"And 2 + 2?">>}
            ],
    {Usage2, AssistantText2} = profile_turn(Url, ConvId, Turn2Messages),
    Turn3Messages =
        Turn2Messages ++
            [
                #{<<"role">> => <<"assistant">>, <<"content">> => AssistantText2},
                #{<<"role">> => <<"user">>, <<"content">> => <<"And 3 + 3?">>}
            ],
    {Usage3, _} = profile_turn(Url, ConvId, Turn3Messages),
    log_usage(1, Usage1),
    log_usage(2, Usage2),
    log_usage(3, Usage3),
    %% Each turn produces a real response.
    ?assert(maps:get(<<"input_tokens">>, Usage1) > 0),
    ?assert(maps:get(<<"input_tokens">>, Usage2) >= maps:get(<<"input_tokens">>, Usage1)),
    ?assert(maps:get(<<"input_tokens">>, Usage3) >= maps:get(<<"input_tokens">>, Usage2)),
    %% With erllama 0.6.0's continue/3 wired in, turn 2 and turn 3
    %% must reuse the predecessor's full committed state instead of
    %% admitting cold. A regression in the session_state plumbing
    %% (lost count, off-by-one slice) would surface as cache_read = 0
    %% on turn 2.
    Read2 = maps:get(<<"cache_read_input_tokens">>, Usage2, 0),
    Read3 = maps:get(<<"cache_read_input_tokens">>, Usage3, 0),
    ?assert(Read2 > 0),
    ?assert(Read3 > Read2).

%% Two-turn /v1/responses conversation chained via
%% previous_response_id. Turn 1 states a fact and yields a resp_ id;
%% the continued turn sends only the new question plus that id. The
%% mechanistic check is that continuation folds the prior turn into
%% the prompt, so the continued request reports strictly more
%% input_tokens than the same question asked cold. The model's recall
%% of the fact is logged for a human to eyeball but not asserted (a
%% tiny test model is not reliable enough to gate CI on).
responses_previous_response_id_continues(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/responses",
    {Id, _T1, _U1} = responses_turn(Url, #{
        <<"model">> => <<"real">>,
        <<"input">> => <<"Remember this fact: my name is Sam.">>,
        <<"max_output_tokens">> => 16,
        <<"stream">> => false
    }),
    ?assert(is_binary(Id) andalso byte_size(Id) > 0),
    %% Control: ask the follow-up cold (no previous_response_id).
    {_BareId, _BareText, BareUsage} = responses_turn(Url, #{
        <<"model">> => <<"real">>,
        <<"input">> => <<"What is my name?">>,
        <<"max_output_tokens">> => 16,
        <<"stream">> => false
    }),
    %% Continued: same question, chained to turn 1.
    {_ContId, ContText, ContUsage} = responses_turn(Url, #{
        <<"model">> => <<"real">>,
        <<"input">> => <<"What is my name?">>,
        <<"previous_response_id">> => Id,
        <<"max_output_tokens">> => 16,
        <<"stream">> => false
    }),
    BareIn = maps:get(<<"input_tokens">>, BareUsage, 0),
    ContIn = maps:get(<<"input_tokens">>, ContUsage, 0),
    ct:log(
        "bare input_tokens=~B continued input_tokens=~B continued_text=~ts",
        [BareIn, ContIn, ContText]
    ),
    ?assert(ContIn > BareIn),
    ?assert(byte_size(ContText) > 0).

%% Drive the agentic continue-loop: register the stub executor for
%% `web_search`, force the model to call it (tool_choice=required) and
%% cap the loop low. The server runs the executor and re-infers each
%% round; the turn must terminate (status=completed) at the cap rather
%% than hang or return a client function_call. The loop engages only
%% for a marker-configured model (wire-driven tool calls); output item
%% types are logged so a human can confirm web_search_call rounds.
responses_server_tool_loop_runs(Cfg) ->
    persistent_term:put(
        {erllama_server_config, builtin_tool_executors},
        #{
            <<"web_search">> => #{
                module => erllama_server_tool_executor_stub,
                type => <<"web_search">>
            }
        }
    ),
    persistent_term:put({erllama_server_config, max_tool_iterations}, 2),
    try
        Url = ?config(base, Cfg) ++ "/v1/responses",
        Body = json:encode(#{
            <<"model">> => <<"real">>,
            <<"input">> => <<"Search the web for today's date.">>,
            <<"tools">> => [#{<<"type">> => <<"web_search">>}],
            <<"tool_choice">> => <<"required">>,
            <<"max_output_tokens">> => 32,
            <<"stream">> => false
        }),
        {ok, {{_, 200, _}, _, Resp}} = httpc:request(
            post, {Url, [], "application/json", Body}, [{timeout, 240000}], []
        ),
        Decoded = json:decode(list_to_binary(Resp)),
        Types = [maps:get(<<"type">>, I) || I <- maps:get(<<"output">>, Decoded, [])],
        ct:log("server-tool loop output types: ~p", [Types]),
        ?assertEqual(<<"completed">>, maps:get(<<"status">>, Decoded))
    after
        persistent_term:erase({erllama_server_config, builtin_tool_executors}),
        persistent_term:erase({erllama_server_config, max_tool_iterations})
    end.

responses_turn(Url, Body) ->
    {ok, {{_, 200, _}, _, Resp}} = httpc:request(
        post,
        {Url, [], "application/json", json:encode(Body)},
        [{timeout, 120000}],
        []
    ),
    Decoded = json:decode(list_to_binary(Resp)),
    Id = maps:get(<<"id">>, Decoded),
    Usage = maps:get(<<"usage">>, Decoded),
    {Id, responses_output_text(Decoded), Usage}.

responses_output_text(Decoded) ->
    case maps:get(<<"output">>, Decoded, []) of
        [#{<<"content">> := [#{<<"text">> := T} | _]} | _] when is_binary(T) -> T;
        _ -> <<>>
    end.

log_usage(TurnN, Usage) ->
    Input = maps:get(<<"input_tokens">>, Usage, 0),
    Output = maps:get(<<"output_tokens">>, Usage, 0),
    Read = maps:get(<<"cache_read_input_tokens">>, Usage, 0),
    Created = maps:get(<<"cache_creation_input_tokens">>, Usage, 0),
    ct:log(
        "turn ~B: input=~B output=~B cache_read=~B cache_creation=~B",
        [TurnN, Input, Output, Read, Created]
    ).

profile_turn(Url, ConvId, Messages) ->
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"messages">> => Messages,
        <<"max_tokens">> => 32,
        <<"stream">> => false
    }),
    Headers = [{"x-conversation-id", binary_to_list(ConvId)}],
    {ok, {{_, 200, _}, _, Resp}} = httpc:request(
        post,
        {Url, Headers, "application/json", Body},
        [{timeout, 120000}],
        []
    ),
    Decoded = json:decode(list_to_binary(Resp)),
    Usage = maps:get(<<"usage">>, Decoded),
    [Block | _] = maps:get(<<"content">>, Decoded),
    Text = maps:get(<<"text">>, Block, <<>>),
    {Usage, Text}.

embeddings_runs(Cfg) ->
    Url = ?config(base, Cfg) ++ "/v1/embeddings",
    Body = json:encode(#{
        <<"model">> => <<"real">>,
        <<"input">> => ?SHORT_PROMPT
    }),
    case httpc:request(post, {Url, [], "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, Resp}} ->
            Decoded = json:decode(list_to_binary(Resp)),
            [Entry] = maps:get(<<"data">>, Decoded),
            Vec = maps:get(<<"embedding">>, Entry),
            ?assert(is_list(Vec)),
            ?assert(length(Vec) > 0);
        {ok, {{_, 501, _}, _, _}} ->
            {skip, "model has no embedding support"};
        {ok, {{_, Code, _}, _, ErrBody}} ->
            ct:fail({embeddings_failed, Code, ErrBody})
    end.

%%====================================================================
%% Helpers
%%====================================================================

http_post(Url, Body) ->
    {ok, {{_, 200, _}, _, RespBody}} =
        httpc:request(post, {Url, [], "application/json", Body}, [], []),
    list_to_binary(RespBody).

has_content_delta(Line) ->
    binary:match(Line, <<"\"content\":">>) =/= nomatch andalso
        binary:match(Line, <<"data: ">>) =/= nomatch.

%% Crude extraction: pull the value of `"content": "..."` out of a
%% chat.completion.chunk JSON. Real test value is just "non-empty".
extract_content(Line) ->
    case
        re:run(
            Line,
            <<"\"content\":\"([^\"]*)\"">>,
            [{capture, all_but_first, binary}]
        )
    of
        {match, [V]} -> V;
        nomatch -> <<>>
    end.
