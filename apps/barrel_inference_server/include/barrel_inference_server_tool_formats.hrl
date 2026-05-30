%% Tool-call format families registered with the server. Ordered
%% top-to-bottom by chat-template detection priority: the first
%% family whose `detect/1' returns `{detected, _}' on a given
%% chat template wins. Specific predicates (multiple substrings)
%% precede generic ones (single substring). `bare-json' never
%% auto-detects (runtime-configured catch-all) so it sits last.
%%
%% Adding a tool-call format family: drop a new module under
%% `apps/barrel_inference_server/src/tool_formats/' implementing
%% `-behaviour(barrel_inference_server_tool_format)', then add ONE
%% line to this list. Nothing else changes - the registry map and
%% the dispatch order both derive from this macro.
-define(BARREL_TOOL_FORMAT_FAMILIES, [
    barrel_inference_server_tool_format_qwen3_coder,
    barrel_inference_server_tool_format_glm45,
    barrel_inference_server_tool_format_mistral_args,
    barrel_inference_server_tool_format_phi4_functools,
    barrel_inference_server_tool_format_llama_pythonic,
    barrel_inference_server_tool_format_qwen_xml,
    barrel_inference_server_tool_format_dsml,
    barrel_inference_server_tool_format_llama_python_tag,
    barrel_inference_server_tool_format_mistral_tool_calls,
    barrel_inference_server_tool_format_bare_json
]).
