# ACP protocol types, ported from agentclientprotocol/python-sdk schema.
# Schema ref: v0.11.2  (PROTOCOL_VERSION = 1)

# ── Content blocks ────────────────────────────────────────────────────────────

struct TextContent
    text::String
end

struct ImageContent
    data::String      # base64
    mime_type::String
end

const ContentBlock = Union{TextContent, ImageContent}

# ── Tool-call content ─────────────────────────────────────────────────────────

struct ToolCallLocation
    path::String
    line::Union{Int,Nothing}
end

struct DiffContent
    path::String
    old_text::Union{String,Nothing}
    new_text::String
end

# ── Session-update notifications (agent → client) ────────────────────────────
# Discriminated by "sessionUpdate" field.

abstract type SessionUpdate end

struct AgentMessageChunk <: SessionUpdate
    content::ContentBlock
end

struct UserMessageChunk <: SessionUpdate
    content::ContentBlock
end

struct AgentThoughtChunk <: SessionUpdate
    content::ContentBlock
end

struct PlanEntry
    content::String
    priority::String   # "high" | "medium" | "low"
    status::String     # "pending" | "in_progress" | "completed"
end

struct PlanUpdate <: SessionUpdate
    entries::Vector{PlanEntry}
end

struct ToolCallNotif <: SessionUpdate
    tool_call_id::String
    title::String
    kind::String       # "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other"
    status::String     # "pending" | "in_progress" | "completed" | "failed"
    content::Vector    # Vector of ContentBlock | DiffContent
    locations::Vector{ToolCallLocation}
    # claude-agent-acp surfaces the *actual* tool name and the unparsed input
    # via `_meta.claudeCode.toolName` and `rawInput` on the wire — the parser
    # reads them out so downstream consumers can dispatch on concrete typed
    # `ToolCall`s (`BashCall` / `TodoWriteCall` / …) instead of probing the
    # generic `title` string. Empty `tool_name` means a non-claude-agent
    # backend that didn't fill the meta hint; the dispatcher falls back to
    # `GenericTool`.
    tool_name::String
    raw_input::Dict{String,Any}
    raw::AbstractDict  # untouched ACP update params (for round-trip persistence)
end

struct ToolCallUpdateNotif <: SessionUpdate
    tool_call_id::String
    title::Union{String,Nothing}
    kind::Union{String,Nothing}
    status::Union{String,Nothing}
    content::Vector
    locations::Vector{ToolCallLocation}
    tool_name::Union{String,Nothing}
    raw_input::Union{Dict{String,Any},Nothing}
    raw::AbstractDict
end

struct UnknownUpdate <: SessionUpdate
    session_update::String
    raw::AbstractDict
end

# claude-agent-acp forwards every SUBAGENT session/update (text chunks,
# tool_calls, tool_call_updates of a running Task/Agent tool) as a normal
# update whose `_meta.claudeCode.parentToolUseId` names the parent Task's
# tool_use id; top-level updates carry no such tag. The parser wraps tagged
# updates so the per-turn coalescer (messages.jl) can divert them out of the
# main message stream instead of interleaving subagent prose/tools into the
# top-level reply.
struct SubagentUpdate <: SessionUpdate
    parent_tool_use_id::String
    update::SessionUpdate
end

"""
    parent_tool_use_id(u::SessionUpdate) -> Union{String,Nothing}

The parent Task tool_use id a subagent-originated update is tagged with
(`_meta.claudeCode.parentToolUseId`), or `nothing` for top-level updates.
"""
parent_tool_use_id(::SessionUpdate) = nothing
parent_tool_use_id(u::SubagentUpdate) = u.parent_tool_use_id

# ── Session config options ────────────────────────────────────────────────────
# ACP "Session Config Options": the session-setup response MAY carry a list of
# select-type options (`configOptions`) with their current values; the agent
# notifies changes via `config_option_update` / `current_mode_update` session
# updates. claude-agent-acp reports mode/model/effort this way (plus legacy
# `modes` / claude-specific `models` blocks, which `parse_config_options`
# falls back to for agents that don't send `configOptions`).

struct ConfigOptionChoice
    value::String
    name::String
    description::Union{String,Nothing}
end

struct ConfigOption
    id::String                           # "mode" | "model" | "effort" | …
    name::String                         # human label, e.g. "Model"
    description::Union{String,Nothing}
    category::Union{String,Nothing}      # "mode" | "model" | "thought_level" | …
    current_value::String
    choices::Vector{ConfigOptionChoice}
end

struct ConfigOptionUpdateNotif <: SessionUpdate
    options::Vector{ConfigOption}        # spec: payload is the COMPLETE state
end

struct CurrentModeUpdateNotif <: SessionUpdate
    mode_id::String
end

_opt_desc(x) = x isa AbstractString && !isempty(x) ? String(x) : nothing

function parse_config_option(d::AbstractDict)::ConfigOption
    choices = ConfigOptionChoice[]
    for c in get(d, "options", [])
        c isa AbstractDict || continue
        push!(choices, ConfigOptionChoice(
            String(get(c, "value", "")),
            String(get(c, "name", "")),
            _opt_desc(get(c, "description", nothing))))
    end
    return ConfigOption(
        String(get(d, "id", "")),
        String(get(d, "name", "")),
        _opt_desc(get(d, "description", nothing)),
        _opt_desc(get(d, "category", nothing)),
        String(get(d, "currentValue", "")),
        choices)
end

"""
    parse_config_options(result) -> Vector{ConfigOption}

Typed view over a raw session-setup result (`session/new` / `session/load`).
Primary source is the spec'd `configOptions` list. When absent, synthesizes
options from the legacy `modes` block (ACP spec) and the claude-agent-acp
`models` block, so spec-only agents still yield a usable list.
"""
function parse_config_options(result::AbstractDict)::Vector{ConfigOption}
    raw = get(result, "configOptions", nothing)
    if raw isa AbstractVector && !isempty(raw)
        return [parse_config_option(d) for d in raw if d isa AbstractDict]
    end
    # Fallback synthesis for agents without configOptions.
    opts = ConfigOption[]
    modes = get(result, "modes", nothing)
    if modes isa AbstractDict
        choices = [ConfigOptionChoice(String(get(m, "id", "")),
                                      String(get(m, "name", "")),
                                      _opt_desc(get(m, "description", nothing)))
                   for m in get(modes, "availableModes", []) if m isa AbstractDict]
        isempty(choices) || push!(opts, ConfigOption(
            "mode", "Mode", nothing, "mode",
            String(get(modes, "currentModeId", "")), choices))
    end
    models = get(result, "models", nothing)
    if models isa AbstractDict
        choices = [ConfigOptionChoice(String(get(m, "modelId", "")),
                                      String(get(m, "name", "")),
                                      _opt_desc(get(m, "description", nothing)))
                   for m in get(models, "availableModels", []) if m isa AbstractDict]
        isempty(choices) || push!(opts, ConfigOption(
            "model", "Model", nothing, "model",
            String(get(models, "currentModelId", "")), choices))
    end
    return opts
end

current_choice(o::ConfigOption)::Union{ConfigOptionChoice,Nothing} =
    (i = findfirst(c -> c.value == o.current_value, o.choices);
     i === nothing ? nothing : o.choices[i])

"""
    choice_label(o, c) -> String

Display label for ONE choice. For the MODEL option, "default" is an ALIAS in
claude-agent-acp — the real model lives in the resolved choice's description
("Opus 4.8 with 1M context · Best for everyday, complex tasks"), so we surface
its first segment instead of the word "Default". "(recommended)" is redundant
noise once the real model shows, so strip it. Every other option (mode, effort,
explicit models) shows its plain choice name — their descriptions are
explanations, not values. Cross-agent: reads only standard ACP choice fields.
"""
function choice_label(o::ConfigOption, c::ConfigOptionChoice)::String
    if o.category == "model" && c.value == "default" &&
       c.description !== nothing && !isempty(strip(c.description))
        return String(strip(first(split(c.description, '·'))))
    end
    return String(strip(replace(c.name, r"\s*\(recommended\)\s*$"i => "")))
end

# Short display label for the option's CURRENT value (see `choice_label`).
pill_label(o::ConfigOption)::String =
    (c = current_choice(o); c === nothing ? o.current_value : choice_label(o, c))

# ── Parsing helpers ───────────────────────────────────────────────────────────

function parse_content_block(d::AbstractDict)::ContentBlock
    t = get(d, "type", "")
    if t == "image"
        return ImageContent(get(d, "data", ""), get(d, "mimeType", "image/png"))
    end
    # default: text
    return TextContent(get(d, "text", ""))
end

function parse_tool_content_item(d::AbstractDict)
    t = get(d, "type", "")
    if t == "diff"
        return DiffContent(get(d, "path", ""), get(d, "oldText", nothing), get(d, "newText", ""))
    elseif t == "content"
        return parse_content_block(get(d, "content", Dict()))
    else
        return TextContent("[tool content: $t]")
    end
end

function parse_location(d::AbstractDict)
    # `line` is spec'd as a scalar, but some agents send a non-scalar (a range
    # `[start,end]`, or a malformed value). Coerce anything that isn't an integer
    # to `nothing` instead of letting the `ToolCallLocation` constructor throw
    # `convert(Union{Int,Nothing}, ::Vector)` — which previously surfaced as a
    # swallowed "ACP dispatch failed" warning and dropped the whole frame.
    line = get(d, "line", nothing)
    ToolCallLocation(get(d, "path", ""), line isa Integer ? Int(line) : nothing)
end

# claude-agent-acp tags every tool_call(_update) with the real Claude Code
# tool name + the raw argument dict via the `_meta.claudeCode` envelope. The
# envelope is optional on the spec, so absence is fine — `parse_tool_call`
# falls back to `GenericTool` when `tool_name` is empty.
function parse_claude_meta(params::AbstractDict)
    meta = get(params, "_meta", nothing)
    name = ""
    if meta isa AbstractDict
        cc = get(meta, "claudeCode", nothing)
        if cc isa AbstractDict
            v = get(cc, "toolName", "")
            v isa AbstractString && (name = String(v))
        end
    end
    rinput = get(params, "rawInput", nothing)
    rinput_d = rinput isa AbstractDict ?
                 Dict{String,Any}(String(k) => v for (k, v) in rinput) :
                 Dict{String,Any}()
    return (name, rinput_d)
end

# Defensive extraction of the subagent tag: the `_meta` envelope is optional
# and any level may be missing or malformed — everything short of a non-empty
# string id means "top-level update".
function parse_parent_tool_use_id(params::AbstractDict)::Union{String,Nothing}
    meta = get(params, "_meta", nothing)
    meta isa AbstractDict || return nothing
    cc = get(meta, "claudeCode", nothing)
    cc isa AbstractDict || return nothing
    v = get(cc, "parentToolUseId", nothing)
    return v isa AbstractString && !isempty(v) ? String(v) : nothing
end

function parse_session_update(params::AbstractDict)::SessionUpdate
    u = parse_session_update_kind(params)
    pid = parse_parent_tool_use_id(params)
    return pid === nothing ? u : SubagentUpdate(pid, u)
end

# The kind-discriminated body (untagged view). Split from the public entry so
# the SubagentUpdate wrap happens in exactly one place.
function parse_session_update_kind(params::AbstractDict)::SessionUpdate
    kind = get(params, "sessionUpdate", "")
    if kind == "agent_message_chunk"
        return AgentMessageChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "user_message_chunk"
        return UserMessageChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "agent_thought_chunk"
        return AgentThoughtChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "plan"
        entries = [PlanEntry(get(e, "content", ""), get(e, "priority", "medium"), get(e, "status", "pending"))
                   for e in get(params, "entries", [])]
        return PlanUpdate(entries)
    elseif kind == "tool_call"
        content = [parse_tool_content_item(c) for c in get(params, "content", [])]
        locs = [parse_location(l) for l in get(params, "locations", [])]
        name, rinput = parse_claude_meta(params)
        return ToolCallNotif(
            get(params, "toolCallId", ""),
            get(params, "title", ""),
            get(params, "kind", "other"),
            get(params, "status", "pending"),
            content, locs, name, rinput, params
        )
    elseif kind == "tool_call_update"
        content = [parse_tool_content_item(c) for c in get(params, "content", [])]
        locs = [parse_location(l) for l in get(params, "locations", [])]
        name, rinput = parse_claude_meta(params)
        # Updates often omit meta + rawInput — preserve `nothing` so the
        # dispatcher knows "no new info" vs "agent renamed the tool".
        return ToolCallUpdateNotif(
            get(params, "toolCallId", ""),
            get(params, "title", nothing),
            get(params, "kind", nothing),
            get(params, "status", nothing),
            content, locs,
            isempty(name) ? nothing : name,
            isempty(rinput) ? nothing : rinput,
            params
        )
    elseif kind == "config_option_update"
        # Spec: the payload is the COMPLETE updated configuration state.
        opts = [parse_config_option(d)
                for d in get(params, "configOptions", []) if d isa AbstractDict]
        return ConfigOptionUpdateNotif(opts)
    elseif kind == "current_mode_update"
        # claude-agent-acp sends the new mode under `currentModeId` (verified on
        # the wire, v0.42.0); the ACP spec's own field name is `modeId`. Read the
        # claude form first, fall back to the spec form, so both agents work.
        return CurrentModeUpdateNotif(
            String(get(params, "currentModeId", get(params, "modeId", ""))))
    else
        return UnknownUpdate(kind, params)
    end
end
