%% Copyright (c) 2026 Benoit Chesneau. Licensed under the MIT License.
%% See the LICENSE file at the project root.
%%
-module(barrel_inference_server_fetch).
-moduledoc """
Public façade for the fetch subsystem.

Resolves a model spec, downloads it (with resume + sha256 verification
+ progress events), and returns the local filesystem path. Hits the
local content-addressed cache before going to the network.

Spec syntax:

```
hf://<org>/<repo>/<path>[@<rev>]   # HuggingFace Hub
ollama://<library>/<name>[:<tag>]  # Ollama registry
https://...                        # plain HTTPS
file:///abs/path | /abs/path       # local passthrough (no copy)
```

Concurrent calls for the same spec are deduped: the second caller
waits on the first call's worker rather than racing it.
""".

-export([
    fetch/1,
    fetch/2,
    fetch_async/1,
    fetch_async/2,
    fetch_status/1,
    fetch_await/1,
    fetch_await/2,
    fetch_subscribe/2,
    resolve/1,
    cache_root/0
]).

-export_type([spec/0, opts/0, job_ref/0]).

-type job_ref() :: barrel_inference_server_fetch_srv:job_ref().

-type spec() :: barrel_inference_server_fetch_resolvers:spec().

-type opts() :: #{
    sha256 => binary(),
    progress => pid(),
    timeout => pos_integer(),
    force => boolean(),
    call_timeout => timeout()
}.

%% =============================================================================
%% Public API
%% =============================================================================

-spec fetch(spec()) -> {ok, file:filename_all()} | {error, term()}.
fetch(Spec) ->
    fetch(Spec, #{}).

-spec fetch(spec(), opts()) -> {ok, file:filename_all()} | {error, term()}.
fetch(Spec, Opts) when is_map(Opts) ->
    case barrel_inference_server_fetch_resolvers:parse(Spec) of
        {ok, Parsed} -> dispatch(Parsed, Opts);
        {error, _} = E -> E
    end.

dispatch(Parsed, #{force := true} = Opts) ->
    barrel_inference_server_fetch_srv:download(Parsed, Opts);
dispatch(Parsed, Opts) ->
    case lookup_cached(Parsed) of
        {ok, _} = Hit -> Hit;
        miss -> barrel_inference_server_fetch_srv:download(Parsed, Opts)
    end.

-spec fetch_async(spec()) -> {ok, job_ref()} | {error, term()}.
fetch_async(Spec) ->
    fetch_async(Spec, #{}).

-spec fetch_async(spec(), opts()) -> {ok, job_ref()} | {error, term()}.
fetch_async(Spec, Opts) when is_map(Opts) ->
    case barrel_inference_server_fetch_resolvers:parse(Spec) of
        {ok, Parsed} -> async_dispatch(Parsed, Opts);
        {error, _} = E -> E
    end.

async_dispatch(Parsed, #{force := true} = Opts) ->
    barrel_inference_server_fetch_srv:download_async(Parsed, Opts);
async_dispatch(Parsed, Opts) ->
    case lookup_cached(Parsed) of
        {ok, _Path} ->
            %% Already on disk. Synthesise a JobRef and deliver the
            %% completion message immediately so async callers don't
            %% have to special-case cache hits.
            Hash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
            self() ! {barrel_inference_fetch_done, Hash, lookup_cached(Parsed)},
            {ok, Hash};
        miss ->
            barrel_inference_server_fetch_srv:download_async(Parsed, Opts)
    end.

-spec fetch_status(job_ref()) -> barrel_inference_server_fetch_srv:status_result().
fetch_status(JobRef) -> barrel_inference_server_fetch_srv:status(JobRef).

-spec fetch_await(job_ref()) -> {ok, file:filename_all()} | {error, term()}.
fetch_await(JobRef) -> fetch_await(JobRef, infinity).

-spec fetch_await(job_ref(), timeout()) ->
    {ok, file:filename_all()} | {error, term()} | timeout.
fetch_await(JobRef, Timeout) -> barrel_inference_server_fetch_srv:await(JobRef, Timeout).

-spec fetch_subscribe(job_ref(), pid()) -> ok | not_found.
fetch_subscribe(JobRef, Pid) -> barrel_inference_server_fetch_srv:subscribe(JobRef, Pid).

-spec resolve(spec()) ->
    {ok, barrel_inference_server_fetch_resolvers:parsed()} | {error, term()}.
resolve(Spec) ->
    barrel_inference_server_fetch_resolvers:parse(Spec).

%% =============================================================================
%% Cache root resolution
%% =============================================================================

-spec cache_root() -> {ok, file:filename_all()}.
cache_root() ->
    case application:get_env(barrel_inference_server, model_cache_dir) of
        {ok, Path} when Path =/= undefined ->
            {ok, ensure_string(Path)};
        _ ->
            case os:getenv("XDG_CACHE_HOME") of
                Xdg when is_list(Xdg), Xdg =/= "" ->
                    {ok, filename:join([Xdg, "barrel_inference_server", "models"])};
                _ ->
                    Base = filename:basedir(user_cache, "barrel_inference_server"),
                    {ok, filename:join(Base, "models")}
            end
    end.

%% =============================================================================
%% Internal
%% =============================================================================

%% A `<spec_hash>.ref` file points at a previously-downloaded blob.
%% Confirm both the ref and the blob exist before returning a hit.
lookup_cached({file, AbsBin}) ->
    hit_if_regular(unicode:characters_to_list(AbsBin));
lookup_cached({hf, _Org, _Repo, undefined, _Rev}) ->
    %% Placeholder HF spec; the actual file is picked by an API call
    %% during resolution, so we can't cache-key on the parsed form.
    %% The worker still writes a ref under the resolved spec so the
    %% downloaded blob is reusable once the user passes the explicit
    %% path.
    miss;
lookup_cached(Parsed) ->
    {ok, Root} = cache_root(),
    SpecHash = barrel_inference_server_fetch_resolvers:spec_hash(Parsed),
    RefPath = filename:join([Root, "refs", <<SpecHash/binary, ".ref">>]),
    case file:read_file(RefPath) of
        {ok, BlobBin} -> hit_if_regular(unicode:characters_to_list(BlobBin));
        {error, _} -> miss
    end.

hit_if_regular(Path) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> miss
    end.

ensure_string(B) when is_binary(B) -> unicode:characters_to_list(B);
ensure_string(L) when is_list(L) -> L.
