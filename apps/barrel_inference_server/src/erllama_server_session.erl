%%% Sticky-seq session id derivation.
%%%
%%% erllama 0.5 pins the underlying seq_id to whatever opaque term we
%%% pass on `Params.session_id'. Successive requests with the same id
%%% truncate-and-prefill in place on the warm KV cells instead of
%%% restoring from disk - the difference between a 50 ms next turn
%%% and a 2 s cold restart for chat-heavy workloads like Claude Code.
%%%
%%% No standard inbound conversation-id header exists in the
%%% Anthropic or OpenAI specs, so we fall through a layered chain:
%%%
%%%   1. `x-conversation-id' HTTP header. Opt-in for proxies / SDK
%%%      callers that pass `extra_headers' on the request. Length-
%%%      capped and trimmed.
%%%   2. `metadata.user_id' from the Anthropic body (mirrored onto
%%%      `#erllama_request.user_id'). Claude Code sends a stable
%%%      per-user value here so vanilla clients still get sticky-seq
%%%      benefits across turns from the same user.
%%%   3. SHA-256 over `(model || first user message bytes)'. Server-
%%%      derived only; covers anonymous + OpenAI traffic that has
%%%      neither a header nor a user_id. Retried prompts with the
%%%      same first message naturally share a session.
%%%
%%% All three options return a `binary()'; the engine treats the
%%% session id as opaque, so the encoding only matters for stability
%%% across turns.

-module(erllama_server_session).

-include("erllama_server.hrl").

-export([derive/2]).

-define(MAX_HEADER_BYTES, 256).

-spec derive(cowboy_req:req(), #erllama_request{}) -> binary().
derive(Req, R) ->
    case header_session(Req) of
        <<>> -> fallback_session(R);
        Bin -> Bin
    end.

header_session(Req) ->
    case cowboy_req:header(<<"x-conversation-id">>, Req, undefined) of
        Bin when is_binary(Bin) -> sanitise_header(Bin);
        _ -> <<>>
    end.

sanitise_header(Bin) ->
    Trimmed = list_to_binary(string:trim(binary_to_list(Bin))),
    case byte_size(Trimmed) of
        0 -> <<>>;
        N when N > ?MAX_HEADER_BYTES -> <<>>;
        _ -> Trimmed
    end.

fallback_session(#erllama_request{user_id = UserId}) when
    is_binary(UserId), UserId =/= <<>>
->
    UserId;
fallback_session(R) ->
    prefix_hash(R).

prefix_hash(#erllama_request{model_id = Model, messages = Messages}) ->
    First = first_user_message_bytes(Messages),
    Bytes = <<Model/binary, 0, First/binary>>,
    base64:encode(crypto:hash(sha256, Bytes)).

first_user_message_bytes([#{role := <<"user">>, content := C} | _]) ->
    content_to_bin(C);
first_user_message_bytes([_ | Rest]) ->
    first_user_message_bytes(Rest);
first_user_message_bytes([]) ->
    <<>>.

content_to_bin(Bin) when is_binary(Bin) ->
    Bin;
content_to_bin(L) when is_list(L) ->
    %% Multi-block content. Stable encoding over the block list is
    %% all we need; the actual bytes are an opaque hash input.
    iolist_to_binary(json:encode(L)).
