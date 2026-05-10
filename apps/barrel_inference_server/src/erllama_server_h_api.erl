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

-module(erllama_server_h_api).
-behaviour(cowboy_handler).

-export([init/2, info/3, terminate/3]).

-record(pull, {
    name :: binary(),
    tag :: binary(),
    spec :: binary(),
    job_ref :: undefined | binary(),
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
init(Req0, #{op := create} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_create/2);
init(Req0, #{op := pull} = Opts) ->
    expect(<<"POST">>, Req0, Opts, fun handle_pull/2).

info({erllama_fetch_progress, Ref, Bytes, Total}, Req, #pull{job_ref = Ref} = St) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - St#pull.last_progress >= 100 of
        true ->
            ok = ndjson_progress(Req, St, Bytes, Total),
            {ok, Req, St#pull{last_progress = Now}};
        false ->
            {ok, Req, St}
    end;
info({erllama_fetch_done, Ref, Result}, Req, #pull{job_ref = Ref} = St) ->
    finalise_pull(Req, St, Result);
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
%% GET /api/tags
%% =============================================================================

handle_tags(Req0, Opts) ->
    Models = [tag_entry(M) || M <- erllama_server_models:list()],
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
            case erllama_server_models:get(Name) of
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
            case erllama_server_models:delete(Name) of
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
            case erllama_server_models:copy(Src, Dst) of
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
%% POST /api/create  (FROM directive only)
%% =============================================================================

handle_create(Req0, Opts) ->
    case read_json(Req0) of
        {ok, #{<<"name">> := Name, <<"modelfile">> := Modelfile}, Req1} ->
            case parse_modelfile(Modelfile) of
                {ok, FromSpec} ->
                    {DstName, DstTag} = split_name_tag(Name),
                    case erllama_server_models:pull(FromSpec, #{name => DstName, tag => DstTag}) of
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

%% v0.1 honours only `FROM <spec>`. Other directives (PARAMETER,
%% TEMPLATE, SYSTEM, ADAPTER, MESSAGE) are flagged so a future
%% revision can wire them into the manifest's loader sub-map.
parse_modelfile(Modelfile) ->
    Lines = binary:split(Modelfile, [<<"\r\n">>, <<"\n">>], [global, trim]),
    case scan_modelfile(Lines, undefined) of
        {ok, undefined} -> {error, modelfile_missing_from};
        {ok, Spec} -> {ok, Spec};
        {error, _} = E -> E
    end.

scan_modelfile([], From) ->
    {ok, From};
scan_modelfile([Line | Rest], From) ->
    case classify_modelfile_line(strip_ws(Line)) of
        skip ->
            scan_modelfile(Rest, From);
        {from, Spec} when From =:= undefined ->
            scan_modelfile(Rest, Spec);
        {from, _} ->
            {error, modelfile_multiple_from};
        {unsupported, Directive} ->
            {error, {modelfile_directive_not_supported, Directive}}
    end.

classify_modelfile_line(<<>>) ->
    skip;
classify_modelfile_line(<<"#", _/binary>>) ->
    skip;
classify_modelfile_line(<<"FROM ", Rest/binary>>) ->
    {from, strip_ws(Rest)};
classify_modelfile_line(<<"from ", Rest/binary>>) ->
    {from, strip_ws(Rest)};
classify_modelfile_line(Line) ->
    [Directive | _] = binary:split(Line, <<" ">>),
    {unsupported, Directive}.

strip_ws(B) ->
    string:trim(B).

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
    case erllama_server_models:resolve_spec(Name) of
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

blocking_pull(Req0, Opts, Spec, Name, Tag) ->
    case erllama_server_models:pull(Spec, #{name => Name, tag => Tag}) of
        {ok, _} ->
            reply(Req0, Opts, 200, #{<<"status">> => <<"success">>});
        {error, Reason} ->
            reply(Req0, Opts, 500, error_body(reason_string(Reason)))
    end.

stream_pull(Req0, Spec, Name, Tag) ->
    Req1 = cowboy_req:stream_reply(
        200, #{<<"content-type">> => <<"application/x-ndjson">>}, Req0
    ),
    ok = ndjson_line(Req1, #{<<"status">> => <<"pulling manifest">>}),
    case
        erllama_server_fetch:fetch_async(
            Spec, #{progress => self()}
        )
    of
        {ok, JobRef} ->
            St = #pull{name = Name, tag = Tag, spec = Spec, job_ref = JobRef},
            {cowboy_loop, Req1, St, hibernate};
        {error, Reason} ->
            ok = ndjson_line(Req1, error_body(reason_string(Reason))),
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

finalise_pull(Req, #pull{name = Name, tag = Tag, spec = Spec} = St, {ok, BlobPath}) ->
    ok = ndjson_line(Req, #{<<"status">> => <<"verifying sha256 digest">>}),
    case erllama_server_models:persist_manifest(Spec, Name, Tag, BlobPath) of
        {ok, _} ->
            ok = ndjson_line(Req, #{<<"status">> => <<"writing manifest">>}),
            ok = ndjson_line(Req, #{<<"status">> => <<"success">>}),
            cowboy_req:stream_body(<<>>, fin, Req),
            {stop, Req, St};
        {error, Reason} ->
            ok = ndjson_line(Req, error_body(reason_string(Reason))),
            cowboy_req:stream_body(<<>>, fin, Req),
            {stop, Req, St}
    end;
finalise_pull(Req, St, {error, Reason}) ->
    ok = ndjson_line(Req, error_body(reason_string(Reason))),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, St}.

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
