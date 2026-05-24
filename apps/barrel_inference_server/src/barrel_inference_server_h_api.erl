%%% Ollama-compatible /api/* endpoints.
%%%
%%% One handler module routes all six operations off the `op` opt
%%% set in the dispatch table. Most ops are short request/response
%%% pairs; `pull` uses cowboy_loop + NDJSON streaming so progress
%%% events flow back as the fetch worker makes progress.
%%%
%%%   GET    /api/tags    -> list models in the registry
%%%   POST   /api/pull    -> pull a model, stream NDJSON status events
%%%   POST   /api/show    -> show one manifest
%%%   DELETE /api/delete  -> remove a manifest (blob preserved)
%%%   POST   /api/copy    -> alias a manifest under a new name:tag
%%%   POST   /api/create  -> create from a Modelfile (FROM only)

-module(barrel_inference_server_h_api).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

-record(pull, {
    name :: binary(),
    tag :: binary(),
    spec :: binary(),
    coord :: undefined | pid(),
    last_progress = 0 :: integer()
}).

%% =============================================================================
%% Cowboy entry
%% =============================================================================

init(Req0, #{op := tags} = Opts) ->
    expect(<<"GET">>, Req0, Opts, fun handle_tags/2);
init(Req0, #{op := show} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_show/2);
init(Req0, #{op := delete} = Opts) ->
    expect(<<"DELETE">>, Req0, Opts, fun handle_delete/2);
init(Req0, #{op := copy} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_copy/2);
init(Req0, #{op := edit} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_edit/2);
init(Req0, #{op := create} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_create/2);
init(Req0, #{op := pull} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_pull/2);
init(Req0, #{op := search} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_search/2);
init(Req0, #{op := version} = Opts) ->
    expect(<<"GET">>, Req0, Opts, fun handle_version/2);
init(Req0, #{op := ps} = Opts) ->
    expect(<<"GET">>, Req0, Opts, fun handle_ps/2).

%% Pull progress/status/outcome events come from the per-pull coordinator
%% (barrel_inference_server_pull), which owns persistence. The handler only
%% relays them to the client as NDJSON; if it dies, the coordinator still
%% finishes and persists.
info({pull_event, Coord, {progress, Bytes, Total}}, Req, #pull{coord = Coord} = St) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - St#pull.last_progress >= 100 of
        true ->
            ok = ndjson_progress(Req, St, Bytes, Total),
            {ok, Req, St#pull{last_progress = Now}};
        false ->
            {ok, Req, St}
    end;
info({pull_event, Coord, {phase, Phase}}, Req, #pull{coord = Coord} = St) ->
    ok = ndjson_line(Req, #{<<"status">> => atom_to_binary(Phase, utf8)}),
    {ok, Req, St};
info({pull_event, Coord, {status, Status}}, Req, #pull{coord = Coord} = St) ->
    ok = ndjson_line(Req, #{<<"status">> => Status}),
    {ok, Req, St};
info({pull_event, Coord, {success, _Manifest}}, Req, #pull{coord = Coord} = St) ->
    ok = ndjson_line(Req, #{<<"status">> => <<"success">>}),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, St};
info({pull_event, Coord, {error, Reason}}, Req, #pull{coord = Coord} = St) ->
    ok = ndjson_line(Req, error_body(reason_string(Reason))),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, St};
info(_, Req, St) ->
    {ok, Req, St}.

terminate(_, _, _) ->
    ok.

%% =============================================================================
%% Method gating
%% =============================================================================

expect(Method, Req0, Opts, Fun) ->
    case cowboy_req:method(Req0) of
        Method ->
            Fun(Req0, Opts);
        _ ->
            Reply = cowboy_req:reply(
                405,
                json_headers(),
                json_body(#{<<"error">> => <<"method_not_allowed">>}),
                Req0
            ),
            {ok, Reply, Opts}
    end.

%% =============================================================================
%% GET /api/version
%% =============================================================================

handle_version(Req0, Opts) ->
    Vsn =
        case application:get_key(barrel_inference_server, vsn) of
            {ok, V} when is_list(V) -> list_to_binary(V);
            {ok, V} when is_binary(V) -> V;
            _ -> <<"0.0.0">>
        end,
    Req1 = cowboy_req:reply(200, json_headers(), json_body(#{<<"version">> => Vsn}), Req0),
    {ok, Req1, Opts}.

%% =============================================================================
%% GET /api/ps
%%
%% Ollama-shape "running" list. Intersection of barrel_inference:list_models/0
%% (loaded gen_statems) with the registry manifests + the keepalive
%% per-model TTL state.
%% =============================================================================

handle_ps(Req0, Opts) ->
    Loaded = safe_list_loaded(),
    Statuses = safe_keepalive_status(),
    StatusMap = maps:from_list([{maps:get(model, S), S} || S <- Statuses]),
    Manifests = manifests_by_name(),
    Models = [ps_entry(Info, StatusMap, Manifests) || Info <- Loaded],
    Req1 = cowboy_req:reply(
        200, json_headers(), json_body(#{<<"models">> => Models}), Req0
    ),
    {ok, Req1, Opts}.

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

iso_or_null(infinity) -> null;
iso_or_null(Ms) when is_integer(Ms) -> iso_from_unix_ms(Ms).

iso_from_unix_ms(Ms) ->
    Seconds = Ms div 1000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])
    ).

%% =============================================================================
%% GET /api/tags
%% =============================================================================

handle_tags(Req0, Opts) ->
    Models = [tag_entry(M) || M <- barrel_inference_server_models:list()],
    Body = #{<<"models">> => Models},
    Req1 = cowboy_req:reply(200, json_headers(), json_body(Body), Req0),
    {ok, Req1, Opts}.

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

%% =============================================================================
%% POST /api/show
%% =============================================================================

handle_show(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"name">> := Name}, Req1} ->
            case barrel_inference_server_models:get(Name) of
                {ok, M} ->
                    reply(Req1, Opts, 200, show_body(M));
                {error, not_found} ->
                    reply(Req1, Opts, 404, error_body(<<"model_not_found">>));
                {error, Reason} ->
                    reply(Req1, Opts, 500, error_body(reason_string(Reason)))
            end;
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing name">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

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
            <<"context_length">> => maps:get(<<"context_size">>, M, null),
            <<"embedding_length">> => maps:get(<<"embedding_length">>, M, null)
        }
    }.

modelfile_for(M) ->
    Spec = maps:get(<<"spec">>, M, <<>>),
    iolist_to_binary([<<"FROM ">>, Spec, <<"\n">>]).

%% =============================================================================
%% DELETE /api/delete
%% =============================================================================

handle_delete(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"name">> := Name}, Req1} ->
            case barrel_inference_server_models:delete(Name) of
                ok ->
                    Req2 = cowboy_req:reply(200, json_headers(), <<>>, Req1),
                    {ok, Req2, Opts};
                {error, not_found} ->
                    reply(Req1, Opts, 404, error_body(<<"model_not_found">>));
                {error, Reason} ->
                    reply(Req1, Opts, 500, error_body(reason_string(Reason)))
            end;
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing name">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

%% =============================================================================
%% POST /api/copy
%% =============================================================================

handle_copy(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"source">> := Src, <<"destination">> := Dst}, Req1} ->
            case barrel_inference_server_models:copy(Src, Dst) of
                ok ->
                    Req2 = cowboy_req:reply(200, json_headers(), <<>>, Req1),
                    {ok, Req2, Opts};
                {error, not_found} ->
                    reply(Req1, Opts, 404, error_body(<<"model_not_found">>));
                {error, Reason} ->
                    reply(Req1, Opts, 500, error_body(reason_string(Reason)))
            end;
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing source/destination">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

%% =============================================================================
%% POST /api/edit
%% =============================================================================
%%
%% Body: `{"name": "model:tag", "parameters": {"num_batch": 512, ...}}'.
%%
%% Merges the supplied PARAMETER values into the manifest's
%% `parameters' sub-map and persists atomically. Keys not in the
%% request body stay intact; keys in the body overwrite. Returns
%% the updated manifest in the same envelope as `/api/show'.
%%
%% The loaded model (if any) keeps running with its current
%% `context_opts'; the new values take effect on the next admit
%% after the model unloads (via `keep_alive' expiry or a
%% `keep_alive: 0' request). The loader honours `parameters.num_X'
%% over `loader.n_X' on the next load.

handle_edit(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"name">> := Name, <<"parameters">> := Params}, Req1} when
            is_map(Params)
        ->
            case barrel_inference_server_models:edit(Name, Params) of
                {ok, Updated} ->
                    reply(Req1, Opts, 200, show_body(Updated));
                {error, not_found} ->
                    reply(Req1, Opts, 404, error_body(<<"model_not_found">>));
                {error, bad_parameters} ->
                    reply(Req1, Opts, 400, error_body(<<"bad_parameters">>));
                {error, Reason} ->
                    reply(Req1, Opts, 500, error_body(reason_string(Reason)))
            end;
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing name/parameters">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

%% =============================================================================
%% POST /api/create  (FROM directive only)
%% =============================================================================

handle_create(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"name">> := Name, <<"modelfile">> := Modelfile}, Req1} ->
            case parse_modelfile(Modelfile) of
                {ok, FromSpec, Overrides} ->
                    {DstName, DstTag} = split_name_tag(Name),
                    PullOpts = #{
                        name => DstName, tag => DstTag, modelfile_overrides => Overrides
                    },
                    case barrel_inference_server_models:pull(FromSpec, PullOpts) of
                        {ok, _} ->
                            Req2 = cowboy_req:reply(200, json_headers(), <<>>, Req1),
                            {ok, Req2, Opts};
                        {error, Reason} ->
                            reply(Req1, Opts, 500, error_body(reason_string(Reason)))
                    end;
                {error, Reason} ->
                    reply(Req1, Opts, 400, error_body(reason_string(Reason)))
            end;
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing name/modelfile">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

%% Returns {ok, FromSpec, Overrides} where Overrides is a map with
%% optional keys `system`, `template`, and `parameters` (itself a map
%% of string -> json-encodable value).
%%
%% v0.1 supports FROM, PARAMETER, SYSTEM, and TEMPLATE. ADAPTER,
%% MESSAGE, and LICENSE still return 400 modelfile_directive_not_supported.
parse_modelfile(Modelfile) ->
    Lines = binary:split(Modelfile, [<<"\r\n">>, <<"\n">>], [global, trim]),
    case scan_modelfile(Lines, #{from => undefined, parameters => #{}}) of
        {ok, #{from := undefined}} ->
            {error, modelfile_missing_from};
        {ok, #{from := Spec} = Acc} ->
            Overrides = strip_undef(maps:remove(from, Acc)),
            {ok, Spec, Overrides};
        {error, _} = E ->
            E
    end.

scan_modelfile([], Acc) ->
    {ok, Acc};
scan_modelfile([Line | Rest], Acc) ->
    case classify_modelfile_line(strip_ws(Line)) of
        skip ->
            scan_modelfile(Rest, Acc);
        {from, _Spec} when map_get(from, Acc) =/= undefined ->
            {error, modelfile_multiple_from};
        {from, Spec} ->
            scan_modelfile(Rest, Acc#{from => Spec});
        {system, Text} ->
            scan_modelfile(Rest, Acc#{system => Text});
        {template, Text} ->
            scan_modelfile(Rest, Acc#{template => Text});
        {parameter, K, V} ->
            Params = maps:get(parameters, Acc, #{}),
            scan_modelfile(Rest, Acc#{parameters => Params#{K => V}});
        {unsupported, Directive} ->
            {error, {modelfile_directive_not_supported, Directive}};
        {error, _} = E ->
            E
    end.

classify_modelfile_line(<<>>) ->
    skip;
classify_modelfile_line(<<"#", _/binary>>) ->
    skip;
classify_modelfile_line(Line) ->
    case binary:split(Line, <<" ">>) of
        [Directive, Rest] -> classify_directive(uppercase(Directive), strip_ws(Rest));
        [Single] -> {unsupported, Single}
    end.

classify_directive(<<"FROM">>, Rest) ->
    {from, Rest};
classify_directive(<<"SYSTEM">>, Rest) ->
    {system, unquote(Rest)};
classify_directive(<<"TEMPLATE">>, Rest) ->
    {template, unquote(Rest)};
classify_directive(<<"PARAMETER">>, Rest) ->
    case binary:split(Rest, <<" ">>) of
        [K, V] -> {parameter, K, decode_param_value(strip_ws(V))};
        _ -> {error, {bad_parameter, Rest}}
    end;
classify_directive(D, _) ->
    {unsupported, D}.

uppercase(Bin) ->
    list_to_binary(string:uppercase(binary_to_list(Bin))).

unquote(<<"\"", _/binary>> = Bin) ->
    Size = byte_size(Bin),
    case Size >= 2 andalso binary:at(Bin, Size - 1) =:= $" of
        true -> binary:part(Bin, 1, Size - 2);
        false -> Bin
    end;
unquote(Bin) ->
    Bin.

%% Parameter values: numbers stay numbers; everything else stays binary.
decode_param_value(B) ->
    try binary_to_integer(B) of
        N -> N
    catch
        _:_ ->
            try binary_to_float(B) of
                F -> F
            catch
                _:_ -> unquote(B)
            end
    end.

strip_undef(M) ->
    maps:filter(fun(_, V) -> V =/= undefined end, M).

strip_ws(B) ->
    string:trim(B).

%% =============================================================================
%% POST /api/search
%% =============================================================================

handle_search(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"query">> := Query} = Body, Req1} ->
            Limit = maps:get(<<"limit">>, Body, 20),
            {ok, Hits} = barrel_inference_server_search:search(Query, #{limit => Limit}),
            reply(Req1, Opts, 200, #{<<"hits">> => Hits});
        {ok, _, Req1} ->
            reply(Req1, Opts, 400, error_body(<<"missing query">>));
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

%% =============================================================================
%% POST /api/pull (NDJSON streaming)
%% =============================================================================

handle_pull(Req0, Opts) ->
    case read_json(Req0) of
        {ok, Body, Req1} ->
            case maps:find(<<"name">>, Body) of
                {ok, Name} ->
                    Stream = maps:get(<<"stream">>, Body, true),
                    TagOverride = maps:get(<<"tag">>, Body, undefined),
                    dispatch_pull(Req1, Opts, Name, TagOverride, Stream);
                error ->
                    reply(Req1, Opts, 400, error_body(<<"missing name">>))
            end;
        {error, Req1, Status} ->
            reply(Req1, Opts, Status, error_body(<<"bad_request">>))
    end.

dispatch_pull(Req0, Opts, Name, TagOverride, Stream) ->
    case barrel_inference_server_models:resolve_spec(Name) of
        {ok, Spec, DefName, DefTag} ->
            Tag = pick_tag(TagOverride, DefTag),
            case Stream of
                true -> stream_pull(Req0, Spec, DefName, Tag);
                _ -> blocking_pull(Req0, Opts, Spec, DefName, Tag)
            end;
        {error, Reason} ->
            reply(Req0, Opts, 400, error_body(reason_string(Reason)))
    end.

pick_tag(undefined, Default) -> Default;
pick_tag(<<>>, Default) -> Default;
pick_tag(Tag, _) when is_binary(Tag) -> Tag.

%% Non-streaming pull. Drive the same coordinator, but block on its
%% outcome. On timeout we reply with an HTTP error yet leave the
%% coordinator running, so the download still completes and the manifest
%% still persists in the background.
blocking_pull(Req0, Opts, Spec, Name, Tag) ->
    case barrel_inference_server_pull_sup:start_pull(Spec, Name, Tag, #{}, [self()]) of
        {ok, Coord} ->
            Mon = monitor(process, Coord),
            Timeout = application:get_env(
                barrel_inference_server, pull_blocking_timeout_ms, 1800000
            ),
            await_blocking_pull(Req0, Opts, Coord, Mon, Timeout);
        {error, Reason} ->
            reply(Req0, Opts, 500, error_body(reason_string(Reason)))
    end.

await_blocking_pull(Req0, Opts, Coord, Mon, Timeout) ->
    receive
        {pull_event, Coord, {success, _Manifest}} ->
            demonitor(Mon, [flush]),
            reply(Req0, Opts, 200, #{<<"status">> => <<"success">>});
        {pull_event, Coord, {error, Reason}} ->
            demonitor(Mon, [flush]),
            reply(Req0, Opts, 500, error_body(reason_string(Reason)));
        {pull_event, Coord, _Other} ->
            await_blocking_pull(Req0, Opts, Coord, Mon, Timeout);
        {'DOWN', Mon, process, Coord, _Reason} ->
            reply(Req0, Opts, 500, error_body(<<"pull failed">>))
    after Timeout ->
        demonitor(Mon, [flush]),
        reply(
            Req0,
            Opts,
            504,
            error_body(<<"pull timed out; continuing in background">>)
        )
    end.

stream_pull(Req0, Spec, Name, Tag) ->
    Req1 = cowboy_req:stream_reply(
        200, #{<<"content-type">> => <<"application/x-ndjson">>}, Req0
    ),
    ok = ndjson_line(Req1, #{<<"status">> => <<"pulling manifest">>}),
    case barrel_inference_server_pull_sup:start_pull(Spec, Name, Tag, #{}, [self()]) of
        {ok, Coord} ->
            St = #pull{name = Name, tag = Tag, spec = Spec, coord = Coord},
            {cowboy_loop, Req1, St, hibernate};
        {error, Reason} ->
            ok = ndjson_line(Req1, error_body(reason_string(Reason))),
            cowboy_req:stream_body(<<>>, fin, Req1),
            {ok, Req1, #pull{name = Name, tag = Tag, spec = Spec}}
    end.

ndjson_progress(Req, St, Bytes, Total) ->
    ndjson_line(Req, #{
        <<"status">> => digest_status(St),
        <<"digest">> => St#pull.spec,
        <<"total">> => or_null(Total),
        <<"completed">> => Bytes
    }).

digest_status(#pull{spec = Spec}) ->
    iolist_to_binary([<<"pulling ">>, Spec]).

%% =============================================================================
%% Utilities
%% =============================================================================

read_json(Req0) ->
    {ok, Bin, Req1} = cowboy_req:read_body(Req0),
    case Bin of
        <<>> ->
            {ok, #{}, Req1};
        _ ->
            try json:decode(Bin) of
                M when is_map(M) -> {ok, M, Req1};
                _ -> {error, Req1, 400}
            catch
                _:_ -> {error, Req1, 400}
            end
    end.

reply(Req0, Opts, Status, BodyMap) ->
    Req1 = cowboy_req:reply(Status, json_headers(), json_body(BodyMap), Req0),
    {ok, Req1, Opts}.

error_body(Msg) when is_binary(Msg) ->
    #{<<"error">> => Msg}.

json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.

json_body(M) ->
    iolist_to_binary(json:encode(M)).

ndjson_line(Req, M) ->
    Line = [json:encode(M), <<"\n">>],
    cowboy_req:stream_body(Line, nofin, Req),
    ok.

split_name_tag(Bin) ->
    case binary:split(Bin, <<":">>) of
        [N] -> {N, <<"latest">>};
        [N, <<>>] -> {N, <<"latest">>};
        [N, T] -> {N, T}
    end.

reason_string(B) when is_binary(B) ->
    B;
reason_string(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
reason_string(T) ->
    iolist_to_binary(io_lib:format("~p", [T])).

or_null(undefined) -> null;
or_null(V) -> V.
