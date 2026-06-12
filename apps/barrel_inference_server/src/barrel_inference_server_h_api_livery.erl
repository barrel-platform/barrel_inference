%%% Livery-side handler for the Ollama-shaped /api/* endpoints. Phase
%%% γ2: GET ops only (tags, version, ps). The POST ops (show, delete,
%%% copy, edit, create, search) and the streaming pull op land in
%%% follow-up PRs.

-module(barrel_inference_server_h_api_livery).

-export([tags/1, version/1, ps/1]).
-export([show/1, delete/1, copy/1, edit/1, create/1, search/1]).
-export([pull/1]).

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
    handle_ok_or_error(barrel_inference_server_models:delete(Name)).

copy(Req) ->
    with_json_body(Req, fun(Body) ->
        case {maps:find(<<"source">>, Body), maps:find(<<"destination">>, Body)} of
            {{ok, Src}, {ok, Dst}} -> copy_run(Src, Dst);
            _ -> err(400, <<"missing source/destination">>)
        end
    end).

copy_run(Src, Dst) ->
    handle_ok_or_error(barrel_inference_server_models:copy(Src, Dst)).

%% Common reply shape for ops that return ok (200 empty body) or one of
%% the standard error tuples.
handle_ok_or_error(ok) ->
    livery_resp:json(200, <<>>);
handle_ok_or_error({error, not_found}) ->
    err(404, <<"model_not_found">>);
handle_ok_or_error({error, Reason}) ->
    err(500, reason_string(Reason)).

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
%% POST /api/pull (NDJSON streaming)
%%====================================================================

pull(Req) ->
    with_json_body(Req, fun(Body) -> pull_dispatch(Body) end).

pull_dispatch(Body) ->
    case maps:find(<<"name">>, Body) of
        {ok, Name} ->
            Stream = maps:get(<<"stream">>, Body, true),
            TagOverride = maps:get(<<"tag">>, Body, undefined),
            pull_resolve(Name, TagOverride, Stream);
        error ->
            err(400, <<"missing name">>)
    end.

pull_resolve(Name, TagOverride, Stream) ->
    case barrel_inference_server_models:resolve_spec(Name) of
        {ok, Spec, DefName, DefTag} ->
            Tag = pick_tag(TagOverride, DefTag),
            case Stream of
                true -> pull_stream(Spec, DefName, Tag);
                _ -> pull_blocking(Spec, DefName, Tag)
            end;
        {error, Reason} ->
            err(400, reason_string(Reason))
    end.

pick_tag(undefined, Default) -> Default;
pick_tag(<<>>, Default) -> Default;
pick_tag(Tag, _) when is_binary(Tag) -> Tag.

pull_blocking(Spec, Name, Tag) ->
    case barrel_inference_server_pull_sup:start_pull(Spec, Name, Tag, #{}, [self()]) of
        {ok, Coord} ->
            Mon = monitor(process, Coord),
            Timeout = application:get_env(
                barrel_inference_server, pull_blocking_timeout_ms, 1800000
            ),
            await_pull(Coord, Mon, Timeout);
        {error, Reason} ->
            err(500, reason_string(Reason))
    end.

await_pull(Coord, Mon, Timeout) ->
    receive
        {pull_event, Coord, {success, _Manifest}} ->
            demonitor(Mon, [flush]),
            livery_resp:json(200, json:encode(#{<<"status">> => <<"success">>}));
        {pull_event, Coord, {error, Reason}} ->
            demonitor(Mon, [flush]),
            err(500, reason_string(Reason));
        {pull_event, Coord, _Other} ->
            await_pull(Coord, Mon, Timeout);
        {'DOWN', Mon, process, Coord, _Reason} ->
            err(500, <<"pull failed">>)
    after Timeout ->
        demonitor(Mon, [flush]),
        err(504, <<"pull timed out; continuing in background">>)
    end.

pull_stream(Spec, Name, Tag) ->
    livery_resp:stream(
        200,
        [{<<"content-type">>, <<"application/x-ndjson">>}],
        fun(Emit) -> stream_pull_drive(Emit, Spec, Name, Tag) end
    ).

stream_pull_drive(Emit, Spec, Name, Tag) ->
    _ = emit_line(Emit, #{<<"status">> => <<"pulling manifest">>}),
    case barrel_inference_server_pull_sup:start_pull(Spec, Name, Tag, #{}, [self()]) of
        {ok, Coord} ->
            stream_pull_loop(Emit, Spec, Coord, 0);
        {error, Reason} ->
            _ = emit_line(Emit, #{<<"error">> => reason_string(Reason)}),
            ok
    end.

stream_pull_loop(Emit, Spec, Coord, LastProgress) ->
    receive
        {pull_event, Coord, Event} ->
            handle_pull_event(Event, Emit, Spec, Coord, LastProgress)
    end.

handle_pull_event({progress, Bytes, Total}, Emit, Spec, Coord, LastProgress) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - LastProgress >= 100 of
        true -> emit_progress_and_loop(Emit, Spec, Coord, Now, Bytes, Total);
        false -> stream_pull_loop(Emit, Spec, Coord, LastProgress)
    end;
handle_pull_event({phase, Phase}, Emit, Spec, Coord, LastProgress) ->
    _ = emit_line(Emit, #{<<"status">> => atom_to_binary(Phase, utf8)}),
    stream_pull_loop(Emit, Spec, Coord, LastProgress);
handle_pull_event({status, Status}, Emit, Spec, Coord, LastProgress) ->
    _ = emit_line(Emit, #{<<"status">> => Status}),
    stream_pull_loop(Emit, Spec, Coord, LastProgress);
handle_pull_event({success, _Manifest}, Emit, _Spec, _Coord, _LastProgress) ->
    _ = emit_line(Emit, #{<<"status">> => <<"success">>}),
    ok;
handle_pull_event({error, Reason}, Emit, _Spec, _Coord, _LastProgress) ->
    _ = emit_line(Emit, #{<<"error">> => reason_string(Reason)}),
    ok.

emit_progress_and_loop(Emit, Spec, Coord, Now, Bytes, Total) ->
    Line = #{
        <<"status">> => digest_status(Spec),
        <<"digest">> => Spec,
        <<"total">> => or_null(Total),
        <<"completed">> => Bytes
    },
    case emit_line(Emit, Line) of
        ok -> stream_pull_loop(Emit, Spec, Coord, Now);
        closed -> ok
    end.

digest_status(Spec) ->
    iolist_to_binary([<<"pulling ">>, Spec]).

or_null(undefined) -> null;
or_null(V) -> V.

emit_line(Emit, M) ->
    case Emit([json:encode(M), <<"\n">>]) of
        ok -> ok;
        {error, _} -> closed
    end.

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
