%%% JSON Schema -> GBNF grammar for tool-call constrained sampling.
%%%
%%% Used by the chat / messages handlers when an OpenAI/Anthropic
%%% request carries a `tools[]` array. The output is a GBNF string
%%% accepted by `llama_sampler_init_grammar` (via erllama's
%%% `set_grammar`/`clear_sampler` plumbing).
%%%
%%% Grammar shape (depending on `tool_choice`):
%%%
%%%   auto      ::= text_response | tool_response
%%%   required  ::= tool_response
%%%   {named,N} ::= tool_response_<N>     (only that tool's schema)
%%%
%%% `text_response` is just any UTF-8 byte until EOS - so the model
%%% can also produce normal assistant text. `tool_response` is a
%%% one-of over per-tool object schemas, with each tool's
%%% `arguments` constrained to its JSON schema.
%%%
%%% This is a v0.1 grammar generator: it covers the JSON Schema
%%% subset the OpenAI / Anthropic SDKs emit (object, string, number,
%%% integer, boolean, array, enum, required) plus oneOf at the top
%%% level. `format`, `pattern`, `items` constraints, and other
%%% advanced features fall back to permissive types.

-module(erllama_server_grammar).

-include("erllama_server.hrl").

-export([from_tools/2, schema_to_gbnf/1, from_response_format/1]).

-export_type([gbnf/0]).

-type gbnf() :: binary().

%%====================================================================
%% Public API
%%====================================================================

%% Build a grammar binding the model's output to either freeform text
%% (when tool_choice = auto) or a tool call. Returns `{ok, Bin}` or
%% `{error, Reason}`.
-spec from_tools([tool()] | undefined, tool_choice()) ->
    {ok, gbnf()} | {error, term()}.
from_tools(undefined, _Choice) ->
    {ok, no_grammar()};
from_tools([], _Choice) ->
    {ok, no_grammar()};
from_tools(_Tools, none) ->
    {ok, no_grammar()};
from_tools(Tools, Choice) when is_list(Tools) ->
    try
        ToolRules = [
            {tool_rule_name(I), tool_rule(T, I)}
         || {I, T} <- enumerate(filter_tools(Tools, Choice))
        ],
        Top = top_rule(Choice, ToolRules),
        Body = render_rules(
            [{<<"root">>, Top} | ToolRules] ++
                shared_rules()
        ),
        {ok, iolist_to_binary(Body)}
    catch
        throw:{grammar_error, R} -> {error, R}
    end.

%% Render a single JSON Schema fragment as a GBNF body. Exposed for
%% testing.
-spec schema_to_gbnf(map()) -> iodata().
schema_to_gbnf(Schema) ->
    schema_value(Schema).

%% Build a grammar from a response-format directive (OpenAI
%% `response_format` or Ollama `format`). Returns `{ok, <<>>}` for
%% the no-constraint case so callers can install it unconditionally.
-spec from_response_format(
    text | json_object | {json_schema, map()}
) -> {ok, gbnf()} | {error, term()}.
from_response_format(text) ->
    {ok, no_grammar()};
from_response_format(json_object) ->
    %% Any valid JSON value. Reuses the shared `value` non-terminal.
    Body = render_rules([{<<"root">>, [<<"ws value ws">>]} | shared_rules()]),
    {ok, iolist_to_binary(Body)};
from_response_format({json_schema, Schema}) when is_map(Schema) ->
    try
        Body = render_rules(
            [{<<"root">>, schema_value(Schema)} | shared_rules()]
        ),
        {ok, iolist_to_binary(Body)}
    catch
        throw:{grammar_error, R} -> {error, R}
    end;
from_response_format(_) ->
    {ok, no_grammar()}.

%%====================================================================
%% Top-level rule
%%====================================================================

top_rule(auto, ToolRules) ->
    %% text_response | one_of_tools
    [<<"text_response | ">>, tool_alternation(ToolRules)];
top_rule(required, ToolRules) ->
    tool_alternation(ToolRules);
top_rule({named, _Name}, [{Rule, _Body}]) ->
    Rule;
top_rule({named, Name}, _) ->
    throw({grammar_error, {unknown_tool, Name}}).

tool_alternation([{R, _}]) ->
    R;
tool_alternation([{First, _} | Rest]) ->
    [First | [[<<" | ">>, N] || {N, _} <- Rest]].

%%====================================================================
%% Per-tool rule
%%====================================================================

tool_rule(#{name := Name, schema := Schema}, _Index) ->
    %% A tool call is a JSON object: {"name":"...", "arguments":...}
    NameLit = json_string_literal(Name),
    Args = schema_value(Schema),
    [
        <<"\"{\" ws \"\\\"name\\\":\" ws ">>,
        NameLit,
        <<" \",\" ws \"\\\"arguments\\\":\" ws ">>,
        Args,
        <<" ws \"}\"">>
    ].

tool_rule_name(I) ->
    iolist_to_binary([<<"tool_">>, integer_to_binary(I)]).

filter_tools(Tools, {named, Name}) ->
    case [T || T = #{name := N} <- Tools, N =:= Name] of
        [] -> throw({grammar_error, {unknown_tool, Name}});
        Sel -> Sel
    end;
filter_tools(Tools, _) ->
    Tools.

%%====================================================================
%% JSON Schema -> GBNF
%%====================================================================

schema_value(#{<<"oneOf">> := Schemas}) ->
    schema_one_of(Schemas);
schema_value(#{<<"enum">> := Enum}) ->
    schema_enum(Enum);
schema_value(Schema) ->
    case schema_type(Schema) of
        <<"object">> -> schema_object(Schema);
        <<"array">> -> schema_array(Schema);
        <<"string">> -> <<"json_string">>;
        <<"integer">> -> <<"json_integer">>;
        <<"number">> -> <<"json_number">>;
        <<"boolean">> -> <<"json_bool">>;
        <<"null">> -> <<"\"null\"">>;
        undefined -> <<"json_value">>
    end.

schema_type(#{<<"type">> := T}) when is_binary(T) -> T;
schema_type(_) -> undefined.

schema_object(Schema) ->
    Properties = props(Schema),
    Required = required(Schema),
    case maps:to_list(Properties) of
        [] ->
            %% Permissive empty object.
            <<"\"{\" ws \"}\"">>;
        Pairs ->
            object_with_props(Pairs, Required)
    end.

object_with_props(Pairs, Required) ->
    %% v0.1 simplification: render the required fields in declaration
    %% order, then any non-required fields. Real JSON allows arbitrary
    %% property order; LLMs in practice follow the schema order.
    {ReqPairs, OptPairs} =
        lists:partition(
            fun({K, _}) -> lists:member(to_binary(K), Required) end,
            Pairs
        ),
    Ordered = ReqPairs ++ OptPairs,
    Items = [object_field(K, V) || {K, V} <- Ordered],
    JoinedReq = join_with(Items, [<<" \",\" ws ">>]),
    [<<"\"{\" ws ">>, JoinedReq, <<" ws \"}\"">>].

object_field(K, V) ->
    Key = json_string_literal(to_binary(K)),
    Val = schema_value(V),
    [Key, <<" \":\" ws ">>, Val].

schema_array(Schema) ->
    Items =
        case
            maps:get(
                <<"items">>,
                Schema,
                maps:get(items, Schema, undefined)
            )
        of
            undefined -> <<"json_value">>;
            S -> schema_value(S)
        end,
    Inner = iolist_to_binary([Items, <<" (\",\" ws ">>, Items, <<")*">>]),
    iolist_to_binary([<<"\"[\" ws (">>, Inner, <<")? ws \"]\"">>]).

schema_one_of(Schemas) ->
    Rendered = [iolist_to_binary(schema_value(S)) || S <- Schemas],
    join_with(Rendered, [<<" | ">>]).

schema_enum(Enum) ->
    Lits = [json_value_literal(V) || V <- Enum],
    join_with(Lits, [<<" | ">>]).

props(#{<<"properties">> := P}) -> P;
props(_) -> #{}.

required(#{<<"required">> := L}) when is_list(L) -> [to_binary(X) || X <- L];
required(_) -> [].

%%====================================================================
%% Shared GBNF library rules
%%
%% Rules referenced by every tool grammar. Mirrors the structure of
%% llama.cpp's `json.gbnf`, trimmed to what we need.
%%====================================================================

shared_rules() ->
    [
        {<<"text_response">>, [<<"[^\\x00]*">>]},
        {<<"json_value">>, [
            <<"json_object | json_array | json_string | json_number ">>,
            <<"| json_bool | \"null\"">>
        ]},
        {<<"json_object">>, [<<"\"{\" ws ( json_member (\",\" ws json_member)* )? ws \"}\"">>]},
        {<<"json_member">>, [<<"json_string \":\" ws json_value">>]},
        {<<"json_array">>, [<<"\"[\" ws ( json_value (\",\" ws json_value)* )? ws \"]\"">>]},
        {<<"json_string">>, [<<"\"\\\"\" json_string_chars* \"\\\"\"">>]},
        {<<"json_string_chars">>, [
            <<"[^\"\\\\\\x00-\\x1f] | \"\\\\\" (\"\\\"\" | \"\\\\\" | \"/\" ">>,
            <<"| \"b\" | \"f\" | \"n\" | \"r\" | \"t\" ">>,
            <<"| \"u\" hex hex hex hex)">>
        ]},
        {<<"hex">>, [<<"[0-9a-fA-F]">>]},
        {<<"json_integer">>, [<<"\"-\"? ([0-9] | [1-9] [0-9]*)">>]},
        {<<"json_number">>, [
            <<"\"-\"? ([0-9] | [1-9] [0-9]*) (\".\" [0-9]+)? ">>,
            <<"([eE] [-+]? [0-9]+)?">>
        ]},
        {<<"json_bool">>, [<<"\"true\" | \"false\"">>]},
        {<<"ws">>, [<<"[ \\t\\n]*">>]}
    ].

%%====================================================================
%% Render
%%====================================================================

render_rules(Pairs) ->
    [render_rule(N, B) || {N, B} <- Pairs].

render_rule(Name, Body) ->
    [Name, <<" ::= ">>, Body, <<"\n">>].

%%====================================================================
%% Helpers
%%====================================================================

enumerate(L) -> enumerate(L, 0).
enumerate([], _) -> [];
enumerate([H | T], I) -> [{I, H} | enumerate(T, I + 1)].

join_with([], _Sep) -> [];
join_with([H], _Sep) -> [H];
join_with([H | T], Sep) -> [H | [[Sep, X] || X <- T]].

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A);
to_binary(L) when is_list(L) -> list_to_binary(L).

%% Render an Erlang term as a GBNF string literal. Strings get
%% double-quotes and `\"` escaping; numbers and bools become their
%% literal text.
json_string_literal(B) when is_binary(B) ->
    Escaped = json_escape(B),
    [<<"\"\\\"">>, Escaped, <<"\\\"\"">>].

json_value_literal(B) when is_binary(B) ->
    json_string_literal(B);
json_value_literal(I) when is_integer(I) ->
    [<<"\"">>, integer_to_binary(I), <<"\"">>];
json_value_literal(F) when is_float(F) ->
    [<<"\"">>, float_to_binary(F, [{decimals, 6}, compact]), <<"\"">>];
json_value_literal(true) ->
    <<"\"true\"">>;
json_value_literal(false) ->
    <<"\"false\"">>;
json_value_literal(null) ->
    <<"\"null\"">>.

%% Escape a JSON string for embedding inside a GBNF string literal.
%% The embedding goes through two layers of escapes (GBNF string,
%% then JSON string), so a literal `"` becomes `\\\"` in the source
%% binary -> `\"` on disk.
json_escape(B) ->
    Escaped = binary:replace(B, <<"\\">>, <<"\\\\">>, [global]),
    binary:replace(Escaped, <<"\"">>, <<"\\\"">>, [global]).

no_grammar() -> <<>>.
