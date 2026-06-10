%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
%% @doc Minimal Prometheus text-format parser for the barrel digest.
%%
%% Pulls the `barrel_inference_*' series the operator cares about into a
%% structured map, so an MCP client gets a digest instead of raw
%% exposition. Pure (no I/O) and unit-testable.
%% @end
-module(barrel_inference_mcp_metrics).

-export([digest/1, parse/1]).

%% @doc Parse a Prometheus exposition body into the operator digest:
%% ```
%% #{models_loaded => integer(),
%%   per_model => #{Model => #{queue_depth, active_streams, resident_bytes,
%%                             pool_exhausted_total,
%%                             cache => #{exact, partial, cold},
%%                             tokens_per_second_avg}}}
%% '''
-spec digest(binary()) -> map().
digest(Body) ->
    Samples = parse(Body),
    Acc = lists:foldl(fun fold_sample/2, #{models_loaded => 0, per_model => #{}}, Samples),
    Per = maps:get(per_model, Acc),
    Acc#{per_model => maps:map(fun(_Model, M) -> finalize_model(M) end, Per)}.

%% Turn the histogram sum/count into an average tps and drop the raw fields.
finalize_model(M0) ->
    case {maps:get(tps_sum, M0, undefined), maps:get(tps_count, M0, undefined)} of
        {Sum, Count} when is_number(Sum), is_number(Count), Count > 0 ->
            M1 = maps:remove(tps_sum, maps:remove(tps_count, M0)),
            M1#{tokens_per_second_avg => Sum / Count};
        _ ->
            maps:remove(tps_sum, maps:remove(tps_count, M0))
    end.

%% @doc Parse exposition text into `[{Name, Labels :: map(), Value :: number()}]'.
%% Comment (`#') and blank lines are skipped; only `barrel_inference_*' series
%% are kept.
-spec parse(binary()) -> [{binary(), map(), number()}].
parse(Body) ->
    Lines = binary:split(Body, [<<"\n">>], [global]),
    lists:filtermap(fun parse_line/1, Lines).

%% Internal -----------------------------------------------------------------

parse_line(<<"#", _/binary>>) ->
    false;
parse_line(<<>>) ->
    false;
parse_line(Line0) ->
    Line = string:trim(Line0),
    case Line of
        <<"barrel_inference_", _/binary>> -> split_sample(Line);
        _ -> false
    end.

%% A sample is `name{labels} value' or `name value'. Split on the last space.
split_sample(Line) ->
    case string:split(Line, <<" ">>, trailing) of
        [Series, ValBin] ->
            case to_number(string:trim(ValBin)) of
                error ->
                    false;
                Value ->
                    {Name, Labels} = split_series(Series),
                    {true, {Name, Labels, Value}}
            end;
        _ ->
            false
    end.

split_series(Series) ->
    case string:split(Series, <<"{">>) of
        [Name, LabelsRaw] ->
            Labels = parse_labels(string:trim(LabelsRaw, trailing, [$}])),
            {Name, Labels};
        [Name] ->
            {Name, #{}}
    end.

parse_labels(<<>>) ->
    #{};
parse_labels(Bin) ->
    Pairs = binary:split(Bin, [<<",">>], [global]),
    lists:foldl(fun parse_label/2, #{}, Pairs).

parse_label(Pair, Acc) ->
    case string:split(Pair, <<"=">>) of
        [K, V] ->
            Acc#{string:trim(K) => string:trim(V, both, [$"])};
        _ ->
            Acc
    end.

to_number(Bin) ->
    S = binary_to_list(Bin),
    case string:to_float(S) of
        {error, no_float} ->
            case string:to_integer(S) of
                {error, _} -> error;
                {I, _} -> I
            end;
        {F, _} ->
            F
    end.

%% Fold one sample into the digest ------------------------------------------

fold_sample({<<"barrel_inference_models_loaded">>, _, V}, Acc) ->
    Acc#{models_loaded => V};
fold_sample({<<"barrel_inference_queue_depth">>, L, V}, Acc) ->
    put_model(L, queue_depth, V, Acc);
fold_sample({<<"barrel_inference_active_streams">>, L, V}, Acc) ->
    put_model(L, active_streams, V, Acc);
fold_sample({<<"barrel_inference_resident_bytes">>, L, V}, Acc) ->
    put_model(L, resident_bytes, V, Acc);
fold_sample({<<"barrel_inference_pool_exhausted_total">>, L, V}, Acc) ->
    put_model(L, pool_exhausted_total, V, Acc);
fold_sample({<<"barrel_inference_cache_hits_total">>, L, V}, Acc) ->
    put_cache(L, V, Acc);
fold_sample({<<"barrel_inference_generation_tokens_per_second_sum">>, L, V}, Acc) ->
    put_model(L, tps_sum, V, Acc);
fold_sample({<<"barrel_inference_generation_tokens_per_second_count">>, L, V}, Acc) ->
    put_model(L, tps_count, V, Acc);
fold_sample(_, Acc) ->
    Acc.

put_model(Labels, Key, Value, Acc) ->
    Model = maps:get(<<"model">>, Labels, <<"_">>),
    Per = maps:get(per_model, Acc),
    Cur = maps:get(Model, Per, #{}),
    Acc#{per_model => Per#{Model => Cur#{Key => Value}}}.

put_cache(Labels, Value, Acc) ->
    Model = maps:get(<<"model">>, Labels, <<"_">>),
    Kind = maps:get(<<"kind">>, Labels, <<"unknown">>),
    Per = maps:get(per_model, Acc),
    Cur = maps:get(Model, Per, #{}),
    Cache = maps:get(cache, Cur, #{}),
    Acc#{per_model => Per#{Model => Cur#{cache => Cache#{Kind => Value}}}}.
