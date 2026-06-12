%%% Livery-side handler for the Ollama-shaped /api/* endpoints. Phase
%%% γ2: GET ops only (tags, version, ps). The POST ops (show, delete,
%%% copy, edit, create, search) and the streaming pull op land in
%%% follow-up PRs.

-module(barrel_inference_server_h_api_livery).

-export([tags/1, version/1, ps/1]).
-export([show/1, delete/1, copy/1, edit/1, create/1, search/1]).

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
%% POST ops
%%====================================================================

show(Req) ->
    with_json_body(Req, fun(Body) ->
        case maps:find(<<"name">>, Body) of
            {ok, Name} -> show_lookup(Name);
            error -> err(400, <<"missing name">>)
        end
    end).

show_lookup(Name) ->
    case barrel_inference_server_models:get(Name) of
        {ok, M} -> livery_resp:json(200, json:encode(show_body(M)));
        {error, not_found} -> err(404, <<"model_not_found">>);
        {error, Reason} -> err(500, reason_string(Reason))
    end.

delete(Req) ->
    with_json_body(Req, fun(Body) ->
        case maps:find(<<"name">>, Body) of
            {ok, Name} -> delete_run(Name);
            error -> err(400, <<"missing name">>)
        end
    end).

delete_run(Name) ->
    case barrel_inference_server_models:delete(Name) of
        ok -> livery_resp:json(200, <<>>);
        {error, not_found} -> err(404, <<"model_not_found">>);
        {error, Reason} -> err(500, reason_string(Reason))
    end.

copy(Req) ->
    with_json_body(Req, fun(Body) ->
        case {maps:find(<<"source">>, Body), maps:find(<<"destination">>, Body)} of
            {{ok, Src}, {ok, Dst}} -> copy_run(Src, Dst);
            _ -> err(400, <<"missing source/destination">>)
        end
    end).

copy_run(Src, Dst) ->
    case barrel_inference_server_models:copy(Src, Dst) of
        ok -> livery_resp:json(200, <<>>);
        {error, not_found} -> err(404, <<"model_not_found">>);
        {error, Reason} -> err(500, reason_string(Reason))
    end.

edit(Req) ->
    with_json_body(Req, fun(Body) ->
        case {maps:find(<<"name">>, Body), maps:find(<<"parameters">>, Body)} of
            {{ok, Name}, {ok, Params}} when is_map(Params) ->
                edit_run(Name, Params);
            _ ->
                err(400, <<"missing name/parameters">>)
        end
    end).

edit_run(Name, Params) ->
    case barrel_inference_server_models:edit(Name, Params) of
        {ok, Updated} -> livery_resp:json(200, json:encode(show_body(Updated)));
        {error, not_found} -> err(404, <<"model_not_found">>);
        {error, bad_parameters} -> err(400, <<"bad_parameters">>);
        {error, Reason} -> err(500, reason_string(Reason))
    end.

create(Req) ->
    with_json_body(Req, fun(Body) ->
        case {maps:find(<<"name">>, Body), maps:find(<<"modelfile">>, Body)} of
            {{ok, Name}, {ok, Modelfile}} ->
                create_run(Name, Modelfile);
            _ ->
                err(400, <<"missing name/modelfile">>)
        end
    end).

create_run(Name, Modelfile) ->
    case barrel_inference_server_h_api:parse_modelfile(Modelfile) of
        {ok, FromSpec, Overrides} ->
            {DstName, DstTag} = barrel_inference_server_h_api:split_name_tag(Name),
            PullOpts = #{name => DstName, tag => DstTag, modelfile_overrides => Overrides},
            case barrel_inference_server_models:pull(FromSpec, PullOpts) of
                {ok, _} -> livery_resp:json(200, <<>>);
                {error, Reason} -> err(500, reason_string(Reason))
            end;
        {error, Reason} ->
            err(400, reason_string(Reason))
    end.

search(Req) ->
    with_json_body(Req, fun(Body) ->
        case maps:find(<<"query">>, Body) of
            {ok, Query} ->
                Limit = maps:get(<<"limit">>, Body, 20),
                {ok, Hits} = barrel_inference_server_search:search(Query, #{limit => Limit}),
                livery_resp:json(200, json:encode(#{<<"hits">> => Hits}));
            error ->
                err(400, <<"missing query">>)
        end
    end).

%%====================================================================
%% POST helpers
%%====================================================================

with_json_body(Req, Then) ->
    case barrel_inference_server_body:read(Req) of
        {ok, Bin, _Req1} ->
            case decode_body(Bin) of
                {ok, Map} -> Then(Map);
                error -> err(400, <<"bad_request">>)
            end;
        {too_large, _Req1} ->
            err(413, <<"request_too_large">>)
    end.

decode_body(<<>>) ->
    {ok, #{}};
decode_body(Bin) ->
    try json:decode(Bin) of
        M when is_map(M) -> {ok, M};
        _ -> error
    catch
        _:_ -> error
    end.

err(Status, Msg) when is_binary(Msg) ->
    livery_resp:json(Status, json:encode(#{<<"error">> => Msg})).

show_body(M) ->
    Quant = maps:get(<<"quantization">>, M, null),
    #{
        <<"modelfile">> => modelfile_for(M),
        <<"parameters">> => <<>>,
        <<"template">> => maps:get(<<"chat_template">>, M, null),
        <<"details">> => details(M),
        <<"model_info">> => #{
            <<"general.architecture">> => maps:get(<<"architecture">>, M, null),
            <<"general.size_label">> => maps:get(<<"parameter_size">>, M, null),
            <<"general.file_type">> => Quant,
            <<"context_length">> => effective_context_length(M),
            <<"embedding_length">> => maps:get(<<"embedding_length">>, M, null)
        }
    }.

effective_context_length(M) ->
    case barrel_inference_server_models:effective_context_size(M) of
        undefined -> null;
        N -> N
    end.

modelfile_for(M) ->
    Spec = maps:get(<<"spec">>, M, <<>>),
    iolist_to_binary([<<"FROM ">>, Spec, <<"\n">>]).

reason_string(B) when is_binary(B) -> B;
reason_string(A) when is_atom(A) -> atom_to_binary(A, utf8);
reason_string(T) -> iolist_to_binary(io_lib:format("~p", [T])).

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
