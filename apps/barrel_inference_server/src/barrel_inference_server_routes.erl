%%% HTTP route table. Compiled into a `livery_router` by
%%% `barrel_inference_server_app:start_listener/0`.

-module(barrel_inference_server_routes).

-export([routes/0]).

-export_type([route/0]).

-type route() :: {binary(), binary(), {module(), atom()}}.

-spec routes() -> [route()].
routes() ->
    [
        {<<"GET">>, <<"/health">>, {barrel_inference_server_h_health, liveness}},
        {<<"GET">>, <<"/health/ready">>, {barrel_inference_server_h_health, readiness}},
        {<<"GET">>, <<"/metrics">>, {barrel_inference_server_h_metrics, handle}},
        {<<"GET">>, <<"/v1/models">>, {barrel_inference_server_h_models, list}},
        {<<"GET">>, <<"/v1/models/:model_id">>, {barrel_inference_server_h_models, single}},
        {<<"POST">>, <<"/v1/chat/completions">>, {barrel_inference_server_h_chat, openai}},
        {<<"POST">>, <<"/v1/completions">>, {barrel_inference_server_h_chat, legacy}},
        {<<"POST">>, <<"/v1/responses">>, {barrel_inference_server_h_responses, openai}},
        {<<"POST">>, <<"/v1/messages">>, {barrel_inference_server_h_messages, messages}},
        {<<"POST">>, <<"/v1/messages/count_tokens">>,
            {barrel_inference_server_h_messages, count_tokens}},
        {<<"POST">>, <<"/v1/embeddings">>, {barrel_inference_server_h_embeddings, openai}},
        {<<"GET">>, <<"/api/tags">>, {barrel_inference_server_h_api, tags}},
        {<<"POST">>, <<"/api/pull">>, {barrel_inference_server_h_api, pull}},
        {<<"POST">>, <<"/api/show">>, {barrel_inference_server_h_api, show}},
        {<<"DELETE">>, <<"/api/delete">>, {barrel_inference_server_h_api, delete}},
        {<<"POST">>, <<"/api/copy">>, {barrel_inference_server_h_api, copy}},
        {<<"POST">>, <<"/api/edit">>, {barrel_inference_server_h_api, edit}},
        {<<"POST">>, <<"/api/create">>, {barrel_inference_server_h_api, create}},
        {<<"POST">>, <<"/api/search">>, {barrel_inference_server_h_api, search}},
        {<<"POST">>, <<"/api/generate">>, {barrel_inference_server_h_ollama, generate}},
        {<<"POST">>, <<"/api/chat">>, {barrel_inference_server_h_ollama, chat}},
        {<<"GET">>, <<"/api/version">>, {barrel_inference_server_h_api, version}},
        {<<"GET">>, <<"/api/ps">>, {barrel_inference_server_h_api, ps}},
        {<<"POST">>, <<"/api/embed">>, {barrel_inference_server_h_embeddings, ollama}},
        {<<"POST">>, <<"/api/embeddings">>, {barrel_inference_server_h_embeddings, ollama_legacy}}
    ].
