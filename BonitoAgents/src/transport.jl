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

# What a session starts with besides its prompt. Claude: the AGENTS.md appendix,
# and `perTaskStopAffordance`, which says this client stops background tasks one
# by one (each has its own stop in the task bar). That makes Claude Code's
# interrupt, the chat's Stop, end the turn and spare the background subagents;
# without it a Stop took every running subagent down with the turn, and nothing
# told the agent (2026-10-20). Other agents get no native metadata; the common
# MCP instructions and bt_help deliver their briefing (remote_app.jl).
function session_meta(::ClaudeCodeAgent, state, project_id::AbstractString)
    meta = system_prompt_meta(agents_prompt_appendix(state, project_id))
    m = get!(() -> Dict{String,Any}(), meta, "_meta")
    m["claudeCode"] = Dict{String,Any}("options" => Dict{String,Any}("perTaskStopAffordance" => true))
    return meta
end
session_meta(::Any, state, ::AbstractString) = Dict{String,Any}()
