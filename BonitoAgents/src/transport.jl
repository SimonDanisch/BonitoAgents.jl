# ACP bring-up payload helpers shared by every agent start!.
#
# The line-level transport itself now lives in AgentClientProtocol
# (`WorkerTransport`, the worker dial-back WS — the one concrete transport). What
# stays here is the small payload glue a `WorkerAgent.start!` builds: the
# mcpServers list and the AGENTS.md system-prompt `_meta` extension.

const ACP = AgentClientProtocol

# Standard MCP-list serialisation, shared by every agent bring-up.
mcp_list_payload(mcp_servers) =
    [Dict("name"    => s.name,
          "command" => s.command,
          "args"    => s.args,
          "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
     for s in mcp_servers]

# Server-global system prompt (state_dir/AGENTS.md) as the `_meta` extension
# claude-agent-acp honors on `session/new` / `session/load`:
# `{_meta: {systemPrompt: {type: "preset", preset: "claude_code", append}}}` —
# the text is APPENDED to claude's stock system prompt, so it composes with
# (never replaces) the per-project CLAUDE.md hierarchy. Empty file ⇒ empty
# dict ⇒ the params stay byte-identical to before.
function system_prompt_meta(text::AbstractString)
    isempty(text) && return Dict{String,Any}()
    return Dict{String,Any}("_meta" => Dict{String,Any}(
        "systemPrompt" => Dict{String,Any}(
            "type"   => "preset",
            "preset" => "claude_code",
            "append" => String(text))))
end
