%%% Single source of truth for the HTTP route table.
%%%
%%% Two consumers:
%%%   - `barrel_inference_server_listener_mon' compiles `cowboy_routes/0'
%%%     into a cowboy_router dispatch table.
%%%   - `barrel_inference_server_app' compiles `livery_routes/0' into a
%%%     `livery_router' when the `livery_port' env is set.
%%%
%%% A new endpoint is added once here. The cowboy and livery
%%% shapes both list method, path, handler, and per-route opts so the
%%% only difference is the router compile call.

-module(barrel_inference_server_routes).

-export([cowboy_routes/0, livery_routes/0, not_yet_migrated/1]).

-spec cowboy_routes() -> cowboy_router:routes().
cowboy_routes() ->
    [
        {'_', [
            {"/v1/chat/completions", barrel_inference_server_h_chat, #{api => openai}},
            {"/v1/completions", barrel_inference_server_h_chat, #{api => openai_legacy}},
            {"/v1/responses", barrel_inference_server_h_responses, #{api => openai}},
            {"/v1/messages", barrel_inference_server_h_messages, #{}},
            {"/v1/messages/count_tokens", barrel_inference_server_h_messages, #{op => count_tokens}},
            {"/v1/embeddings", barrel_inference_server_h_embeddings, #{}},
            {"/v1/models", barrel_inference_server_h_models, #{}},
            {"/v1/models/:model_id", barrel_inference_server_h_models, #{}},
            {"/health", barrel_inference_server_h_health, #{kind => liveness}},
            {"/health/ready", barrel_inference_server_h_health, #{kind => readiness}},
            {"/metrics", barrel_inference_server_h_metrics, #{}},
            {"/api/tags", barrel_inference_server_h_api, #{op => tags}},
            {"/api/pull", barrel_inference_server_h_api, #{op => pull}},
            {"/api/show", barrel_inference_server_h_api, #{op => show}},
            {"/api/delete", barrel_inference_server_h_api, #{op => delete}},
            {"/api/copy", barrel_inference_server_h_api, #{op => copy}},
            {"/api/edit", barrel_inference_server_h_api, #{op => edit}},
            {"/api/create", barrel_inference_server_h_api, #{op => create}},
            {"/api/search", barrel_inference_server_h_api, #{op => search}},
            {"/api/generate", barrel_inference_server_h_ollama, #{op => generate}},
            {"/api/chat", barrel_inference_server_h_ollama, #{op => chat}},
            {"/api/version", barrel_inference_server_h_api, #{op => version}},
            {"/api/ps", barrel_inference_server_h_api, #{op => ps}},
            {"/api/embed", barrel_inference_server_h_embeddings, #{api => ollama}},
            {"/api/embeddings", barrel_inference_server_h_embeddings, #{api => ollama_legacy}}
        ]}
    ].

%% Routes for the livery listener. The cowboy `init/2` handler shape
%% does not fit livery's `fun((Req) -> Resp)` model, so livery routes
%% point at the new `handle/1`-style entry points on the same handler
%% modules. Routes whose handler hasn't been migrated yet are listed
%% with a placeholder pointing at the catch-all 503 stub so the listener
%% can boot for the simple-handler subset; γ phase PRs add the
%% streaming entry points and replace the placeholders in lockstep.
-spec livery_routes() -> [livery_route()].
livery_routes() ->
    Stub = {barrel_inference_server_routes, not_yet_migrated},
    [
        {<<"GET">>, <<"/health">>, {barrel_inference_server_h_health, liveness}},
        {<<"GET">>, <<"/health/ready">>, {barrel_inference_server_h_health, readiness}},
        {<<"GET">>, <<"/metrics">>, {barrel_inference_server_h_metrics, handle}},
        {<<"GET">>, <<"/v1/models">>, {barrel_inference_server_h_models, list}},
        {<<"GET">>, <<"/v1/models/:model_id">>, {barrel_inference_server_h_models, single}},
        {<<"POST">>, <<"/v1/chat/completions">>, Stub},
        {<<"POST">>, <<"/v1/completions">>, Stub},
        {<<"POST">>, <<"/v1/responses">>, Stub},
        {<<"POST">>, <<"/v1/messages">>, Stub},
        {<<"POST">>, <<"/v1/messages/count_tokens">>, Stub},
        {<<"POST">>, <<"/v1/embeddings">>, Stub},
        {<<"GET">>, <<"/api/tags">>, Stub},
        {<<"POST">>, <<"/api/pull">>, Stub},
        {<<"POST">>, <<"/api/show">>, Stub},
        {<<"DELETE">>, <<"/api/delete">>, Stub},
        {<<"POST">>, <<"/api/copy">>, Stub},
        {<<"POST">>, <<"/api/edit">>, Stub},
        {<<"POST">>, <<"/api/create">>, Stub},
        {<<"POST">>, <<"/api/search">>, Stub},
        {<<"POST">>, <<"/api/generate">>, Stub},
        {<<"POST">>, <<"/api/chat">>, Stub},
        {<<"GET">>, <<"/api/version">>, Stub},
        {<<"GET">>, <<"/api/ps">>, Stub},
        {<<"POST">>, <<"/api/embed">>, Stub},
        {<<"POST">>, <<"/api/embeddings">>, Stub}
    ].

-type livery_route() :: {binary(), binary(), {module(), atom()}}.

%% Catch-all handler for routes whose cowboy implementation hasn't been
%% ported to a livery `handle/1' yet. Returns 503 with a JSON body
%% explaining the route is only served by the cowboy listener during
%% the migration window. The `target=livery' CT group skips any case
%% that exercises a route still using this stub.
not_yet_migrated(_Req) ->
    livery_resp:json(
        503,
        json:encode(#{
            <<"error">> => <<"not_migrated_to_livery">>,
            <<"hint">> =>
                <<
                    "This route is only served by the cowboy listener "
                    "during the migration window."
                >>
        })
    ).
