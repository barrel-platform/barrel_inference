%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% @doc Tool definitions and handlers for the Barrel Inference MCP server.
%%
%% Each handler is an arity-1 function `(Args :: map()) -> Result' where
%% argument keys are binaries (per the MCP JSON Schema). Handlers return
%% `{structured, Data, Content}' on success or `{tool_error, Content}'
%% for domain failures (pool exhausted, context limit), per the
%% `barrel_mcp' return conventions.
%% @end
-module(barrel_inference_mcp_tools).

-export([register_all/0]).
-export([
    barrel_infer/1,
    barrel_count_tokens/1,
    barrel_list_models/1,
    barrel_show_model/1,
    barrel_edit_model/1,
    barrel_metrics/1,
    barrel_health/1
]).

%% Whitelisted parameters barrel_edit_model is allowed to forward to /api/edit.
-define(EDITABLE, [
    <<"num_ctx">>,
    <<"num_batch">>,
    <<"num_seq_max">>,
    <<"weight_residency">>,
    <<"n_gpu_layers">>
]).

%% @doc Register every barrel tool against barrel_mcp. Called on app start.
-spec register_all() -> ok.
register_all() ->
    ok = reg_infer(),
    ok = reg_count_tokens(),
    ok = reg_list_models(),
    ok = reg_show_model(),
    ok = reg_edit_model(),
    ok = reg_metrics(),
    ok = reg_health(),
    ok.

reg_infer() ->
    reg(
        <<"barrel_infer">>,
        barrel_infer,
        <<
            "Run a single non-streaming completion on the local barrel inference "
            "server. Pass a stable session_id across calls to reuse the KV-cache "
            "prefix (faster on multi-turn)."
        >>,
        obj(
            #{
                <<"model">> => str(<<"Model id or alias (e.g. llama3:8b).">>),
                <<"prompt">> => str(<<"The user prompt to complete.">>),
                <<"max_tokens">> => int(<<"Max tokens to generate (default 512).">>),
                <<"session_id">> =>
                    str(<<"Stable conversation id for KV-cache reuse (optional).">>)
            },
            [<<"model">>, <<"prompt">>]
        )
    ).

reg_count_tokens() ->
    reg(
        <<"barrel_count_tokens">>,
        barrel_count_tokens,
        <<
            "Count input tokens for a prompt against a model, without running "
            "inference. Use before large prompts to check against num_ctx."
        >>,
        obj(
            #{
                <<"model">> => str(<<"Model id or alias.">>),
                <<"prompt">> => str(<<"Text to count.">>)
            },
            [<<"model">>, <<"prompt">>]
        )
    ).

reg_list_models() ->
    reg(
        <<"barrel_list_models">>,
        barrel_list_models,
        <<
            "List registered models merged with currently-resident ones "
            "(load state, expires_at, size_vram)."
        >>,
        obj(#{}, [])
    ).

reg_show_model() ->
    reg(
        <<"barrel_show_model">>,
        barrel_show_model,
        <<
            "Show a model's manifest, including the resolved parameters block "
            "(num_ctx, num_batch, num_seq_max, weight_residency, n_gpu_layers)."
        >>,
        obj(#{<<"model">> => str(<<"Model id or alias.">>)}, [<<"model">>])
    ).

reg_edit_model() ->
    reg(
        <<"barrel_edit_model">>,
        barrel_edit_model,
        <<
            "Edit a model's runtime parameters. Only num_ctx, num_batch, "
            "num_seq_max, weight_residency, n_gpu_layers are accepted."
        >>,
        obj(
            #{
                <<"model">> => str(<<"Model id or alias.">>),
                <<"num_ctx">> => int(<<"Context window size.">>),
                <<"num_batch">> => int(<<"Prefill batch size.">>),
                <<"num_seq_max">> => int(<<"Sequence pool size / concurrency.">>),
                <<"weight_residency">> => enum(
                    <<"Weight residency mode.">>,
                    [<<"eager">>, <<"lazy">>, <<"pinned">>, <<"lazy_then_pin_resident">>]
                ),
                <<"n_gpu_layers">> => int(<<"Layers to offload to GPU.">>)
            },
            [<<"model">>]
        )
    ).

reg_metrics() ->
    reg(
        <<"barrel_metrics">>,
        barrel_metrics,
        <<
            "Structured digest of barrel Prometheus metrics: models_loaded plus "
            "per-model queue_depth, active_streams, resident_bytes, cache hits, "
            "tokens_per_second, pool_exhausted_total."
        >>,
        obj(#{}, [])
    ).

reg_health() ->
    reg(
        <<"barrel_health">>,
        barrel_health,
        <<"Readiness of the barrel daemon and the list of loaded models.">>,
        obj(#{}, [])
    ).

%% Handlers -----------------------------------------------------------------

barrel_infer(Args) ->
    Model = maps:get(<<"model">>, Args),
    Prompt = maps:get(<<"prompt">>, Args),
    MaxTokens = maps:get(<<"max_tokens">>, Args, 512),
    Body = #{
        <<"model">> => Model,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Prompt}],
        <<"max_tokens">> => MaxTokens,
        <<"stream">> => false
    },
    Headers = session_header(Args),
    case barrel_inference_mcp_http:post_json("/v1/chat/completions", Body, Headers) of
        {ok, Code, _H, Json} when Code >= 200, Code < 300 ->
            Choice = first_choice(Json),
            Data = #{
                <<"content">> => msg_content(Choice),
                <<"finish_reason">> => maps:get(<<"finish_reason">>, Choice, null),
                <<"usage">> => maps:get(<<"usage">>, Json, #{})
            },
            structured(Data, msg_content(Choice));
        {ok, 429, _H, _Json} ->
            tool_error(<<
                "barrel busy: pool exhausted for this model. Retry, or "
                "raise num_seq_max with barrel_edit_model."
            >>);
        {ok, 400, _H, Json} ->
            handle_400(Json);
        Other ->
            http_error(Other)
    end.

barrel_count_tokens(Args) ->
    Model = maps:get(<<"model">>, Args),
    Prompt = maps:get(<<"prompt">>, Args),
    Body = #{
        <<"model">> => Model,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Prompt}]
    },
    case barrel_inference_mcp_http:post_json("/v1/messages/count_tokens", Body) of
        {ok, Code, _H, Json} when Code >= 200, Code < 300 ->
            structured(Json, undefined);
        Other ->
            http_error(Other)
    end.

barrel_list_models(_Args) ->
    Models =
        case barrel_inference_mcp_http:get_json("/v1/models") of
            {ok, C1, _H1, J1} when C1 >= 200, C1 < 300 -> maps:get(<<"data">>, J1, []);
            _ -> []
        end,
    Resident =
        case barrel_inference_mcp_http:get_json("/api/ps") of
            {ok, C2, _H2, J2} when C2 >= 200, C2 < 300 -> maps:get(<<"models">>, J2, []);
            _ -> []
        end,
    structured(#{<<"registered">> => Models, <<"resident">> => Resident}, undefined).

barrel_show_model(Args) ->
    Model = maps:get(<<"model">>, Args),
    case barrel_inference_mcp_http:post_json("/api/show", #{<<"name">> => Model}) of
        {ok, Code, _H, Json} when Code >= 200, Code < 300 ->
            structured(Json, undefined);
        {ok, 404, _H, _} ->
            tool_error(<<"model not found: ", Model/binary>>);
        Other ->
            http_error(Other)
    end.

barrel_edit_model(Args) ->
    Model = maps:get(<<"model">>, Args),
    Params = maps:with(?EDITABLE, Args),
    case maps:size(Params) of
        0 ->
            tool_error(<<
                "no editable parameter supplied. Accepted: num_ctx, "
                "num_batch, num_seq_max, weight_residency, n_gpu_layers."
            >>);
        _ ->
            Body = #{<<"model">> => Model, <<"parameters">> => Params},
            case barrel_inference_mcp_http:post_json("/api/edit", Body) of
                {ok, Code, _H, Json} when Code >= 200, Code < 300 ->
                    structured(Json, edit_note(Params));
                Other ->
                    http_error(Other)
            end
    end.

barrel_metrics(_Args) ->
    case barrel_inference_mcp_http:get_text("/metrics") of
        {ok, Code, _H, Body} when Code >= 200, Code < 300 ->
            structured(barrel_inference_mcp_metrics:digest(Body), undefined);
        Other ->
            http_error(Other)
    end.

barrel_health(_Args) ->
    case barrel_inference_mcp_http:get_json("/health/ready") of
        {ok, _Code, _H, Json} when is_map(Json) ->
            structured(Json, undefined);
        Other ->
            http_error(Other)
    end.

%% Helpers ------------------------------------------------------------------

session_header(Args) ->
    case maps:get(<<"session_id">>, Args, undefined) of
        undefined -> [];
        Sid -> [{<<"x-conversation-id">>, Sid}]
    end.

first_choice(Json) ->
    case maps:get(<<"choices">>, Json, []) of
        [Choice | _] -> Choice;
        _ -> #{}
    end.

msg_content(Choice) ->
    Msg = maps:get(<<"message">>, Choice, #{}),
    maps:get(<<"content">>, Msg, <<>>).

handle_400(Json) ->
    Msg = error_message(Json),
    case binary:match(Msg, <<"Context limit">>) of
        nomatch ->
            tool_error(Msg);
        _ ->
            tool_error(<<
                "context limit reached. Raise num_ctx with "
                "barrel_edit_model, then retry."
            >>)
    end.

error_message(Json) when is_map(Json) ->
    case maps:get(<<"error">>, Json, undefined) of
        #{<<"message">> := M} when is_binary(M) -> M;
        M when is_binary(M) -> M;
        _ -> <<"bad request">>
    end;
error_message(_) ->
    <<"bad request">>.

edit_note(Params) ->
    case maps:is_key(<<"num_seq_max">>, Params) of
        true ->
            <<
                "Updated. If you raised num_seq_max, make sure pool concurrency "
                "matches or concurrent sessions can deadlock."
            >>;
        false ->
            <<"Updated. Changes apply on the next load of the model.">>
    end.

http_error({ok, Code, _H, Body}) ->
    tool_error(
        iolist_to_binary(io_lib:format("barrel returned HTTP ~p: ~ts", [Code, body_text(Body)]))
    );
http_error({error, Reason}) ->
    tool_error(
        iolist_to_binary(
            io_lib:format(
                "cannot reach barrel daemon (~0p). Is it "
                "running on ~s?",
                [Reason, barrel_inference_mcp_http:base_url()]
            )
        )
    ).

body_text(Body) when is_binary(Body) -> Body;
body_text(Body) -> json:encode(Body).

%% Return-shape and schema constructors -------------------------------------

structured(Data, undefined) ->
    {structured, Data, [text(json_text(Data))]};
structured(Data, Text) when is_binary(Text) ->
    {structured, Data, [text(Text), text(json_text(Data))]}.

tool_error(Text) ->
    {tool_error, [text(Text)]}.

text(Bin) ->
    #{<<"type">> => <<"text">>, <<"text">> => Bin}.

json_text(Data) ->
    iolist_to_binary(json:encode(Data)).

reg(Name, Fun, Desc, Schema) ->
    barrel_mcp:reg_tool(Name, ?MODULE, Fun, #{description => Desc, input_schema => Schema}).

obj(Props, Required) ->
    #{<<"type">> => <<"object">>, <<"properties">> => Props, <<"required">> => Required}.

str(Desc) ->
    #{<<"type">> => <<"string">>, <<"description">> => Desc}.

int(Desc) ->
    #{<<"type">> => <<"integer">>, <<"description">> => Desc}.

enum(Desc, Values) ->
    #{<<"type">> => <<"string">>, <<"description">> => Desc, <<"enum">> => Values}.
