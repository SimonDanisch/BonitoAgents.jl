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

"""
    tool_call_id(u::SessionUpdate) -> Union{String,Nothing}

The tool call an update is about, or `nothing` for updates that aren't about a
tool. Used to recover an owner the wire omitted: claude-agent-acp does NOT tag
every frame of a subagent's tool — captured live, one tool arrives
`tool_call`(tagged) → `tool_call_update`(UNTAGGED, carrying the toolResponse) →
`tool_call_update`(tagged). The untagged frame is still that subagent's, and its
`toolCallId` says so.
"""
tool_call_id(::SessionUpdate) = nothing
tool_call_id(u::ToolCallNotif) = u.tool_call_id
tool_call_id(u::ToolCallUpdateNotif) = u.tool_call_id
tool_call_id(u::SubagentUpdate) = tool_call_id(u.update)

# Whether an update reports its tool as finished, so a remembered owner can be
# forgotten once its last frame has been delivered.
tool_is_terminal(::SessionUpdate) = false
tool_is_terminal(u::ToolCallNotif) = u.status in ("completed", "failed")
tool_is_terminal(u::ToolCallUpdateNotif) = u.status in ("completed", "failed")
tool_is_terminal(u::SubagentUpdate) = tool_is_terminal(u.update)

"""
    is_agent_work(u::SessionUpdate) -> Bool

Whether `u` is the agent DOING something, as opposed to telling us about the
session. Content the user watches appear — prose, thoughts, tool calls, plans —
is work; `available_commands` / `current_mode` / `session_info` / `usage` are
metadata that arrives on bind and at turn boundaries.

The distinction matters because these updates also arrive with NO prompt open
(see `Unprompted`), and treating every one of them as "the agent is busy" makes a
chat that has done nothing look busy: a fresh session emits
`available_commands_update` right after `session/new`.

`SubagentUpdate` is work, but reaches this only in tests — on the wire it is
addressed to its owner before liveness is ever consulted.
"""
is_agent_work(::SessionUpdate) = false
is_agent_work(::AgentMessageChunk) = true
is_agent_work(::AgentThoughtChunk) = true
is_agent_work(::PlanUpdate) = true
is_agent_work(::ToolCallNotif) = true
is_agent_work(::ToolCallUpdateNotif) = true
is_agent_work(::SubagentUpdate) = true

# ── Autonomous cycles ────────────────────────────────────────────────────────
# claude-agent-acp tags the `usage_update` it sends at a CYCLE'S RESULT with
# `_meta["_claude/origin"].kind`, and that tag is the only end-of-episode signal
# on the wire. When the agent auto-wakes after backgrounded work finishes, it
# streams prose and tools with no prompt open — an episode with an obvious start
# and, without this, no observable end at all.
#
# The set is the adapter's own `AUTONOMOUS_RESULT_ORIGINS` (acp-agent.js): work
# the model did on its own. The user's turn is tagged `human`, and
# `auto-continuation` continues the user's turn, so neither counts. Verified in
# both captured wires — the auto-wake's last frame is a `usage_update` with
# `kind = "task-notification"`.
const AUTONOMOUS_ORIGINS = ("task-notification", "peer", "coordinator",
                            "observer", "observer-activity")

"""
    is_autonomous_origin(kind) -> Bool

Whether an origin tag marks the result of a cycle the model ran on its own.
`nothing` (an untagged frame) is not a result at all, so it is not one.
"""
is_autonomous_origin(::Nothing) = false
is_autonomous_origin(kind::AbstractString) = kind in AUTONOMOUS_ORIGINS

# ── What the session is doing ────────────────────────────────────────────────
# ONE value, replacing the pile of independent booleans this used to be
# (`unprompted_work`, `cancelling`, and — a layer up — `busy_active` and
# `autowake`). Each of those was a latch whose SET and CLEAR lived on different
# code paths, and each had at least one path where the clear never ran:
#
#   * `cancelling` was cleared by a cancelled prompt's response, so cancelling
#     UN-prompted work latched it forever and the session went silent until the
#     user reloaded.
#   * `busy_active`/`autowake` were cleared by a `usage_update` the agent tags
#     with an autonomous origin — which claude-agent-acp emits conditionally and
#     can simply omit — so the spinner ran over an idle agent, and because the
#     composer queues while busy, the chat became unusable.
#
# The rule this type enforces: EVERY state has an exit that does not depend on
# the agent volunteering anything.
abstract type SessionActivity end

"Nothing of ours is open and the agent is not streaming."
struct Idle <: SessionActivity end

"At least one `session/prompt` of ours is open. Ends at its response."
struct Prompted <: SessionActivity end

"""
The agent is working with no prompt of ours open — it auto-woke after
backgrounded work finished, or a background subagent is reporting.

This is the one state the wire gives no end marker for: an auto-wake episode is
prose and tools that simply stop. `AUTONOMOUS_ORIGINS` tags the usual last frame
but is not guaranteed, so it is treated as a hint, never as the only way out —
`quiet_since` bounds the state instead (see `settle`).
"""
struct Unprompted <: SessionActivity end

"A cancel is on the wire and we are waiting for the turn to wind down."
struct Cancelling <: SessionActivity end

"""
Whether the agent has work in flight that a cancel could reach.

`Idle` is the only state where stop has nothing to do — and that is exactly the
moment a UI should treat its own spinner as stale rather than act on it.
"""
is_working(::SessionActivity) = true
is_working(::Idle) = false

# ── The message stream ───────────────────────────────────────────────────────
# Whole, ordered messages coalesced from the raw `session/update` soup. The
# concrete kinds live in messages.jl; the abstract type is here because
# `Connection` needs the boundary marker below.
abstract type Message end

# A boundary on a stream, not content. Travels the stream like a message so it
# arrives in wire order: the coalescer seals its state when it reaches one (the
# trailing text bubble ends, tools the agent never resolved are force-failed),
# then forwards it, and the consumer signals `done` once everything ahead of the
# boundary is rendered.
#
# That is what makes "the turn is over" a checkable fact on a CONTINUOUS stream.
# The main thread does not stop existing between prompts — the agent auto-wakes
# and keeps talking on it — so end-of-turn cannot be "the channel closed". It is
# a marker, and waiting on one is the render barrier end-of-turn cleanup needs.
#
# `done` is a LATCH, not a mailbox: the consumer CLOSES it, and every waiter —
# one, none, or the same caller twice — is released. A one-shot `put!`/`take!`
# looks equivalent and is not: the second `take!` blocks forever on an empty
# channel. That is exactly what an error path does, since it wants the barrier
# both before it renders the error and again in its cleanup.
#
# `bind(done, task)` composes with this: if the renderer dies, the channel closes
# and the waiter is released the same way.
struct StreamFlush <: Message
    done::Channel{Nothing}
    # Whether the span this boundary ends was ABANDONED — i.e. it resolved
    # `cancelled`, so any tool of its that never reported terminal never will.
    #
    # The coalescer needs the distinction because a tool's `updates` channel is
    # closed on its terminal frame, and the CONSUMER blocks draining that
    # channel. A handed-off turn's live tool must survive (a `bt_julia_eval`
    # still running when the next prompt goes out); a CANCELLED turn's live tool
    # must be released, or the consumer waits on a channel nothing will ever
    # close and the whole chat stops rendering — messages pile up unseen until a
    # reload replays them.
    abandoned::Bool
end
StreamFlush(abandoned::Bool = false) = StreamFlush(Channel{Nothing}(1), abandoned)

# Release everyone waiting on this boundary. Idempotent.
signal_rendered!(m::StreamFlush) = (isopen(m.done) && close(m.done); nothing)

# Block until `m` has been rendered (or the renderer is gone). Idempotent, and
# safe to call from several tasks.
function wait_rendered(m::StreamFlush)
    try
        take!(m.done)
    catch e
        e isa InvalidStateException || rethrow()   # closed = signalled
    end
    return nothing
end

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

# Context/cost telemetry (`usage_update`): claude-agent-acp sends it after
# each assistant message — total tokens in context (`used`), the model's
# context window (`size`), and (≥ v0.44) the cumulative session cost. The
# `_meta["_claude/origin"].kind` tag distinguishes autonomous work (e.g.
# "task-notification" follow-ups) from user turns.
struct UsageUpdateNotif <: SessionUpdate
    used::Int
    size::Int
    cost_amount::Union{Float64,Nothing}
    cost_currency::Union{String,Nothing}
    origin_kind::Union{String,Nothing}
end

# One slash command (`available_commands_update`): pushed at session start
# and re-pushed whenever claude's command set changes. `hint` is the
# flattened `input.hint` argument hint, when the command takes arguments.
struct CommandInfo
    name::String
    description::String
    hint::Union{String,Nothing}
end

struct AvailableCommandsUpdateNotif <: SessionUpdate
    commands::Vector{CommandInfo}
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
#
# Other agents don't ship that envelope, but they still identify MCP tools:
# they put the canonical `mcp__<server>__<tool>` name in the ACP `title`.
# Verified against kimi 0.29.2 driving the real btworker server — its
# `tool_call` frame is
#     {"toolCallId":"0:tool_…","title":"mcp__btworker__bt_julia_eval",
#      "kind":"other","status":"pending","content":[…]}
# with NO `_meta` and NO `rawInput` anywhere in the turn. Without the fallback
# below `tool_name` stays empty, every such call lands in `GenericTool`, and
# BonitoAgents renders a bare generic card instead of the typed eval card —
# the same tool looking completely different depending on which agent ran it.
#
# The fallback is deliberately narrow: only a title in the `mcp__a__b` form is
# taken as a name, which is the exact shape `build_tool_call` already parses
# and not something a human-readable title collides with. A title that isn't in
# that form leaves `tool_name` empty and behaves exactly as before.
function parse_claude_meta(params::AbstractDict; title_names::Bool = false)
    meta = get(params, "_meta", nothing)
    name = ""
    if meta isa AbstractDict
        cc = get(meta, "claudeCode", nothing)
        if cc isa AbstractDict
            v = get(cc, "toolName", "")
            v isa AbstractString && (name = String(v))
        end
    end
    if isempty(name)
        t = get(params, "title", nothing)
        if t isa AbstractString &&
           (is_mcp_tool_name(t) || (title_names && looks_like_tool_name(t)))
            name = String(t)
        end
    end
    rinput = get(params, "rawInput", nothing)
    rinput_d = rinput isa AbstractDict ?
                 Dict{String,Any}(String(k) => v for (k, v) in rinput) :
                 Dict{String,Any}()
    return (name, rinput_d)
end

# A bare tool NAME rather than a human-readable title. Kimi labels its native
# tools with Claude's own names — `Read`, `Bash`, `Agent` — on the opening
# `tool_call`, which is the only thing that identifies e.g. a shell call as a
# shell call once `_meta` is absent. It then REPLACES the title on a later frame
# with a sentence ("Reading hello.txt", "Running: echo …", "Launching explore
# agent: …"), so the name is only trustworthy on that opening frame — hence the
# `title_names` opt-in, set for `tool_call` and NOT for `tool_call_update`.
#
# Whitespace is the discriminator: every real tool name is a single token, and
# every human title kimi produced contains a space. A non-matching title just
# leaves the name empty, exactly as before.
looks_like_tool_name(s::AbstractString) =
    !isempty(s) && ncodeunits(s) <= 64 && !occursin(r"\s", s)

# `mcp__<server>__<tool>` with both parts non-empty — the MCP naming convention
# every ACP agent uses for tools it got from an MCP server.
function is_mcp_tool_name(s::AbstractString)
    startswith(s, "mcp__") || return false
    rest = SubString(s, 6)
    sep = findfirst("__", String(rest))
    sep === nothing && return false
    return first(sep) > 1 && last(sep) < lastindex(rest)
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
        # Opening frame: the title may still be the bare tool name (see
        # `looks_like_tool_name`), which is the only handle a non-claude agent
        # gives us on WHICH tool this is.
        name, rinput = parse_claude_meta(params; title_names = true)
        return ToolCallNotif(
            get(params, "toolCallId", ""),
            get(params, "title", ""),
            get(params, "kind", "other"),
            get(params, "status", "pending"),
            content, locs, name, rinput, params
        )
    elseif kind == "tool_call_update"
        content = [parse_tool_content_item(c) for c in get(params, "content", [])]
        # claude-agent-acp ships a FAILED MCP tool's result as a bare
        # `rawOutput` STRING with NO content blocks (verified on acp.jsonl:
        # the fused "```julia\n…\n```\nerror:\n…" text of a bt_julia_eval
        # DomainError) — success frames carry real content blocks instead.
        # Normalize the asymmetry HERE so every downstream consumer (snaps,
        # persistence, renderers) only ever sees content. Terminal frames
        # only: a mid-flight rawOutput would race the real content blocks.
        if isempty(content) && get(params, "status", nothing) in ("completed", "failed")
            rout = get(params, "rawOutput", nothing)
            rout isa AbstractString && !isempty(rout) &&
                (content = [TextContent(String(rout))])
        end
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
    elseif kind == "usage_update"
        # Wire shape (verified, claude-agent-acp v0.44.0 source + logs):
        # {used:: tokens in context, size:: context window, cost::
        # {amount, currency} (≥ 0.44), _meta::{"_claude/origin"::{kind,…}}}.
        cost = get(params, "cost", nothing)
        meta = get(params, "_meta", nothing)
        origin = meta isa AbstractDict ? get(meta, "_claude/origin", nothing) : nothing
        okind = origin isa AbstractDict ? get(origin, "kind", nothing) : nothing
        return UsageUpdateNotif(
            round(Int, get(params, "used", 0)),
            round(Int, get(params, "size", 0)),
            cost isa AbstractDict ? Float64(get(cost, "amount", 0.0)) : nothing,
            cost isa AbstractDict ? String(get(cost, "currency", "USD")) : nothing,
            okind isa AbstractString ? String(okind) : nothing)
    elseif kind == "available_commands_update"
        cmds = CommandInfo[]
        for c in get(params, "availableCommands", [])
            c isa AbstractDict || continue
            input = get(c, "input", nothing)
            hint = input isa AbstractDict ? get(input, "hint", nothing) : nothing
            push!(cmds, CommandInfo(
                String(get(c, "name", "")),
                String(get(c, "description", "")),
                hint isa AbstractString ? String(hint) : nothing))
        end
        return AvailableCommandsUpdateNotif(cmds)
    else
        return UnknownUpdate(kind, params)
    end
end
