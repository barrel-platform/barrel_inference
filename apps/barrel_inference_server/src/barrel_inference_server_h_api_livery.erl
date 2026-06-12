%%% Livery-side handler for the Ollama-shaped /api/* endpoints. Phase
%%% γ2: GET ops only (tags, version, ps). The POST ops (show, delete,
%%% copy, edit, create, search) and the streaming pull op land in
%%% follow-up PRs.

-module(barrel_inference_server_h_api_livery).

-export([tags/1, version/1, ps/1]).

tags(_Req) ->
    Models = [tag_entry(M) || M <- barrel_inference_server_models:list()],
    livery_resp:json(200, json:encode(#{<<"models">> => Models})).

version(_Req) ->
    Vsn =
        case application:get_key(barrel_inference_server, vsn) of
            {ok, V} when is_list(V) -> list_to_binary(V);
            {ok, V} when is_binary(V) -> V;
            _ -> <<"0.0.0">>
        end,
    livery_resp:json(200, json:encode(#{<<"version">> => Vsn})).

ps(_Req) ->
    Loaded = safe_list_loaded(),
    Statuses = safe_keepalive_status(),
    StatusMap = maps:from_list([{maps:get(model, S), S} || S <- Statuses]),
    Manifests = manifests_by_name(),
    Models = [ps_entry(Info, StatusMap, Manifests) || Info <- Loaded],
    livery_resp:json(200, json:encode(#{<<"models">> => Models})).

%%====================================================================
%% Internal (duplicated locally for the migration window; once γ
%% completes these can be merged back into h_api as shared exports).
%%====================================================================

safe_list_loaded() ->
    try barrel_inference:list_models() of
        L when is_list(L) -> L
    catch
        _:_ -> []
    end.

safe_keepalive_status() ->
    try barrel_inference_server_keepalive:status() of
        L when is_list(L) -> L
    catch
        _:_ -> []
    end.

manifests_by_name() ->
    Ms = barrel_inference_server_models:list(),
    maps:from_list([
        {<<(maps:get(<<"name">>, M))/binary, ":", (maps:get(<<"tag">>, M))/binary>>, M}
     || M <- Ms
    ]).

ps_entry(Info, StatusMap, Manifests) ->
    Id = maps:get(id, Info, <<>>),
    Manifest = maps:get(Id, Manifests, #{}),
    KeepAlive = maps:get(Id, StatusMap, #{}),
    #{
        <<"name">> => Id,
        <<"model">> => Id,
        <<"size">> => maps:get(<<"size_bytes">>, Manifest, 0),
        <<"digest">> => maps:get(<<"digest">>, Manifest, null),
        <<"details">> => details(Manifest),
        <<"expires_at">> => iso_or_null(maps:get(expires_at_ms, KeepAlive, infinity)),
        <<"size_vram">> => maps:get(<<"size_bytes">>, Manifest, 0)
    }.

tag_entry(M) ->
    Name = maps:get(<<"name">>, M),
    Tag = maps:get(<<"tag">>, M, <<"latest">>),
    #{
        <<"name">> => <<Name/binary, ":", Tag/binary>>,
        <<"modified_at">> => maps:get(<<"modified_at">>, M, <<>>),
        <<"size">> => maps:get(<<"size_bytes">>, M, 0),
        <<"digest">> => maps:get(<<"digest">>, M, null),
        <<"details">> => details(M)
    }.

details(M) ->
    #{
        <<"format">> => maps:get(<<"format">>, M, <<"gguf">>),
        <<"family">> => maps:get(<<"family">>, M, null),
        <<"parameter_size">> => maps:get(<<"parameter_size">>, M, null),
        <<"quantization_level">> => maps:get(<<"quantization">>, M, null)
    }.

iso_or_null(infinity) -> null;
iso_or_null(Ms) when is_integer(Ms) -> iso_from_unix_ms(Ms).

iso_from_unix_ms(Ms) ->
    Seconds = Ms div 1000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])
    ).
