# Whole, ordered messages coalesced from the raw `session/update` soup.
#
# The dispatcher feeds one turn's `SessionUpdate`s into a channel; `prompt!`
# runs a bounded loop that turns them into clean `Message`s. A streaming
# message (agent text, thought, user echo) carries its OWN `updates` channel,
# closed at the message boundary, so the chat layer renders one bubble per
# message and drains that bubble's stream with `append!`. The wire-parse types
# (`AgentMessageChunk`, `ToolCallNotif`, …) never escape this file.

abstract type Message end

const ToolContent = Union{TextContent, DiffContent, ImageContent}

mutable struct AgentMessage <: Message
    text::String                 # seeded with the first chunk
    updates::Channel{String}     # later deltas; closed when the message ends
end
mutable struct Thought <: Message
    text::String
    updates::Channel{String}
end
mutable struct UserMessage <: Message
    text::String
    updates::Channel{String}
end
"""
    ToolCall <: Message

Abstract family for one tool invocation in a turn. Concrete subtypes carry
tool-specific arguments (`BashCall.run_in_background`, `TodoWriteCall.entries`,
…) so consumers dispatch on the type instead of probing strings.

All variants share the five "header" fields the ACP wire defines (`id`,
`kind`, `title`, `status`, `content`) plus an `updates::Channel` that yields
the (mutated) call after each `tool_call_update`. New variants get added when
a tool's behavior diverges enough that an opaque arg dict isn't enough — for
everything else, `GenericTool` carries the raw input.
"""
abstract type ToolCall <: Message end

# Every concrete variant declares the same five header fields + `updates`,
# either via Composition (header struct field) or by direct duplication.
# Direct duplication wins on dispatch transparency: `tc.kind` and `tc.status`
# Just Work without `getproperty` overrides.

mutable struct GenericTool <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    name::String                       # actual tool name from `_meta.claudeCode.toolName`
    raw_input::Dict{String,Any}
end

mutable struct BashCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    command::String
    run_in_background::Bool
    description::Union{String,Nothing}
end

mutable struct TodoWriteCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    entries::Vector{PlanEntry}
end

mutable struct TaskCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    description::String
    prompt::String
    run_in_background::Bool
    task_name::Union{String,Nothing}
    # For an ASYNC (`run_in_background`) subagent, claude-agent-acp hands back an
    # `outputFile` in the launch response's `_meta.claudeCode.toolResponse` (the
    # subagent's transcript file on the worker). It's the ONLY deterministic
    # completion signal for a detached subagent — the parent tool_call is marked
    # `completed` at LAUNCH, never at real completion — so downstream polls this
    # file (fd-close) exactly like a background bash's output file. "" until the
    # async-launch update arrives.
    output_file::String
end

mutable struct MCPCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    server::String                     # "bonitoagents"
    tool_name::String                  # bare name without `mcp__server__` prefix
    raw_input::Dict{String,Any}
end

struct Plan <: Message
    entries::Vector{PlanEntry}
end

# Session-config changes mid-turn. Metadata, not content: they don't open a
# bubble and don't close the currently-streaming message.
struct ConfigUpdate <: Message
    options::Vector{ConfigOption}        # complete updated state (spec)
end
struct ModeUpdate <: Message
    mode_id::String
end
# Context/cost telemetry after each assistant message. Metadata, not content —
# same rules as ConfigUpdate (no bubble, doesn't close the streaming message).
struct UsageUpdate <: Message
    used::Int
    size::Int
    cost_amount::Union{Float64,Nothing}
    cost_currency::Union{String,Nothing}
    origin_kind::Union{String,Nothing}
end
# The agent's slash-command set (complete state, re-pushed on change).
struct CommandsUpdate <: Message
    commands::Vector{CommandInfo}
end

# A fresh streaming message, seeded with its first chunk.
AgentMessage(t::AbstractString) = AgentMessage(String(t), Channel{String}(BUF))
Thought(t::AbstractString)      = Thought(String(t), Channel{String}(BUF))
UserMessage(t::AbstractString)  = UserMessage(String(t), Channel{String}(BUF))

# Closing a message closes its own stream. The ToolCall arm is one method that
# covers every concrete variant (GenericTool / BashCall / TodoWriteCall / …)
# because they all share the `updates::Channel{ToolCall}` field.
Base.close(m::AgentMessage) = close(m.updates)
Base.close(m::Thought)      = close(m.updates)
Base.close(m::UserMessage)  = close(m.updates)
Base.close(m::ToolCall)     = close(m.updates)

# Appending a chunk feeds the message's stream.
Base.append!(m::AgentMessage, t::AbstractString) = (put!(m.updates, String(t)); m)
Base.append!(m::Thought, t::AbstractString)      = (put!(m.updates, String(t)); m)
Base.append!(m::UserMessage, t::AbstractString)  = (put!(m.updates, String(t)); m)

# Materialize a streaming message by draining its own stream into its fields,
# so the fully-assembled value can outlive the stream. Used for history replay,
# which has no live UI to stream into — we want the whole message at once. Must
# run concurrently with the producer (the stream closes at the next message
# boundary). Text messages accumulate `text`; a `ToolCall` is mutated in place
# by `parse_update!`, so draining just advances to its final state.
function drain_message!(m::Union{AgentMessage,Thought,UserMessage})
    for delta in m.updates
        m.text *= delta
    end
    return m
end
function drain_message!(m::ToolCall)
    for _ in m.updates
    end
    return m
end
drain_message!(m::Plan) = m
drain_message!(m::ConfigUpdate) = m
drain_message!(m::ModeUpdate) = m

# ── Wire → typed dispatch ────────────────────────────────────────────────────
# One place maps Claude Code's tool name to a concrete `ToolCall` subtype.
# After this, downstream code (BonitoAgents's `build_msg`, persistence, taskbar)
# dispatches on the subtype — no more `tool.kind == "execute" && ...` probes.
build_tool_call(n::ToolCallNotif) =
    build_tool_call(Val(Symbol(n.tool_name)), n)

# Bash (one-shot or background) — pull command + the run_in_background flag
# out of the raw input so consumers can route background bashes to the taskbar
# without re-probing the args dict.
function build_tool_call(::Val{:Bash}, n::ToolCallNotif)
    return BashCall(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        String(get(n.raw_input, "command", "")),
        get(n.raw_input, "run_in_background", false) === true,
        _opt_str(get(n.raw_input, "description", nothing)),
    )
end

function build_tool_call(::Val{:TodoWrite}, n::ToolCallNotif)
    entries = PlanEntry[]
    raw_entries = get(n.raw_input, "todos", get(n.raw_input, "entries", []))
    if raw_entries isa AbstractVector
        for e in raw_entries
            e isa AbstractDict || continue
            push!(entries, PlanEntry(
                String(get(e, "content", "")),
                String(get(e, "priority", "medium")),
                String(get(e, "status", "pending"))))
        end
    end
    return TodoWriteCall(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        entries,
    )
end

# Claude Code calls its subagent tool `Task` (legacy) and `Agent` (newer SDK).
# Both carry the same shape; we treat them identically.
for sdk_name in (:Task, :Agent)
    @eval function build_tool_call(::Val{$(QuoteNode(sdk_name))}, n::ToolCallNotif)
        return TaskCall(
            n.tool_call_id, n.kind, n.title, n.status,
            Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
            String(get(n.raw_input, "description", "")),
            String(get(n.raw_input, "prompt", "")),
            get(n.raw_input, "run_in_background", false) === true,
            _opt_str(get(n.raw_input, "name", nothing)),
            something(async_output_file(n.raw), ""),   # usually "" on the initial call
        )
    end
end

# The async subagent's transcript file, dug out of a tool_call(_update)'s
# `_meta.claudeCode.toolResponse.outputFile` (present on the `async_launched`
# result). `nothing` when absent (non-async tools, or before the launch ack).
function async_output_file(raw)
    raw isa AbstractDict || return nothing
    meta = get(raw, "_meta", nothing); meta isa AbstractDict || return nothing
    cc = get(meta, "claudeCode", nothing); cc isa AbstractDict || return nothing
    tr = get(cc, "toolResponse", nothing); tr isa AbstractDict || return nothing
    of = get(tr, "outputFile", nothing)
    (of isa AbstractString && !isempty(of)) ? String(of) : nothing
end

# MCP tool names land here as `mcp__<server>__<tool>` (see the BonitoMCP
# routes registered as `bt_*`). Strip the prefix once at parse time so the
# message carries the bare name + server.
function build_tool_call(::Val{name}, n::ToolCallNotif) where {name}
    s = string(name)
    if startswith(s, "mcp__")
        rest = SubString(s, 6)               # drop "mcp__"
        sep = findfirst("__", String(rest))
        if sep !== nothing
            server = String(SubString(rest, 1, prevind(rest, first(sep))))
            tname  = String(SubString(rest, nextind(rest, last(sep))))
            return MCPCall(
                n.tool_call_id, n.kind, n.title, n.status,
                Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
                server, tname,
                n.raw_input,
            )
        end
    end
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        s, n.raw_input,
    )
end

# Fallback when claude-agent-acp didn't fill the meta (`tool_name == ""`):
# we have no name to dispatch on, so the call lands as `GenericTool` with an
# empty name. UX will show the ACP `kind` + `title` like before.
function build_tool_call(::Val{Symbol("")}, n::ToolCallNotif)
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        "", n.raw_input,
    )
end

# Small helpers used by the builders above.
_opt_str(x) = x isa AbstractString && !isempty(x) ? String(x) : nothing

# Convenience for tests / fixtures that build a synthetic ToolCall without
# going through the wire-parse: drop the typed-args, pin name + raw_input
# to defaults. Production code never goes through here — the wire dispatcher
# does — but tests like to construct from positional fields and pass a fresh
# channel. `GenericTool` doubles as the fallback subtype, so existing test
# call sites mechanically port `ACP.ToolCall(...)` → `ACP.GenericTool(...)`.
GenericTool(id::AbstractString, kind::AbstractString, title::AbstractString,
            status::AbstractString, content::AbstractVector,
            updates::Channel = Channel{ToolCall}(BUF)) =
    GenericTool(String(id), String(kind), String(title), String(status),
                Vector{ToolContent}(content), updates,
                "", Dict{String,Any}())

# ── Subagent activity ────────────────────────────────────────────────────────
# One subagent event, distilled from a `SubagentUpdate` for the turn's
# `on_subagent` sink. NOT a `Message`: it is delivered out-of-band (a direct
# sink call from the parse loop), never through the turn's message channel —
# the sequential message consumer can be parked inside a long-running tool's
# snapshot drain, which would starve a channel-delivered feed of exactly the
# live updates it exists to show.
struct SubagentActivity
    parent_id::String    # the parent Task's tool_use id
    kind::Symbol         # :text | :thought | :tool
    tool_id::String      # subagent tool_call id; "" for text/thought
    label::String        # chunk text, or the subagent tool's title
    status::String       # subagent tool status; "" for text/thought
end

# ── Per-turn parser ─────────────────────────────────────────────────────────
# State local to a single prompt loop: the text message currently being
# streamed (if any) plus the set of tools still awaiting completion.
mutable struct TurnState
    current_message::Union{Message,Nothing}
    tools::Dict{String,ToolCall}
    # Everything the current text message has received so far — used by
    # `text!` to drop claude-agent-acp's handoff duplicate (see there).
    acc::String
    # Out-of-band sink for subagent-tagged updates (`SubagentUpdate`), called
    # with each `SubagentActivity` from the parse loop. `nothing` (the
    # default) drops them — they must NEVER fall through into the main
    # message stream. Must be fast and non-throwing; it runs on the turn's
    # coalescer task.
    on_subagent::Union{Function,Nothing}
end
TurnState() = TurnState(nothing, Dict{String,ToolCall}(), "", nothing)
TurnState(on_subagent::Union{Function,Nothing}) =
    TurnState(nothing, Dict{String,ToolCall}(), "", on_subagent)

# Closing the turn finishes the trailing message and any still-open tools.
#
# Any tool still in `st.tools` is one the agent NEVER reported terminal for —
# the turn ended (cancel, EOF, peer hang-up) before its `tool_call_update` with
# a completed/failed status arrived. Force it to `"failed"` and push ONE final
# snapshot through its `updates` channel BEFORE closing, so downstream consumers
# (BonitoAgents's `process_update!`) see a terminal status and finalize naturally —
# instead of draining a channel that just-closed with the status frozen mid-flight.
function Base.close(st::TurnState)
    st.current_message === nothing || close(st.current_message)
    st.current_message = nothing
    for tc in values(st.tools)
        if !is_terminal(tc.status)
            tc.status = "failed"
            push_snapshot!(tc.updates, tc)
        end
        close(tc)
    end
    empty!(st.tools)
    return nothing
end

is_terminal(status::AbstractString) = status in ("completed", "failed")

# Push the latest tool-call snapshot WITHOUT blocking (A7). A `ToolCall` is
# mutated in place, so every queued entry is the SAME object — only the most
# recent state matters. If a UI consumer abandoned `tc.updates` and let the
# buffer fill, a plain `put!` would block the per-turn parse loop, which would
# in turn stop draining the dispatcher's `updates` channel and wedge the whole
# turn. Drop-oldest keeps us moving; a closed channel (consumer gone) is a
# no-op.
function push_snapshot!(ch::Channel{ToolCall}, tc::ToolCall)
    while true
        lock(ch)
        try
            isopen(ch) || return nothing
            if Base.n_avail(ch) < ch.sz_max
                put!(ch, tc)
                return nothing
            end
        finally
            unlock(ch)
        end
        try
            take!(ch)
        catch e
            e isa InvalidStateException && return nothing
            rethrow()
        end
    end
end

text_of(u::AgentMessageChunk) = u.content isa TextContent ? u.content.text : nothing
text_of(u::AgentThoughtChunk) = u.content isa TextContent ? u.content.text : nothing
text_of(u::UserMessageChunk)  = u.content isa TextContent ? u.content.text : nothing

# Three thin arms — the only place the wire chunk types appear — pick which
# message kind a text delta belongs to; everything else is `append!`/`close`.
parse_update!(out, st, u::AgentMessageChunk) = text!(out, st, AgentMessage, text_of(u))
parse_update!(out, st, u::AgentThoughtChunk) = text!(out, st, Thought,      text_of(u))
parse_update!(out, st, u::UserMessageChunk)  = text!(out, st, UserMessage,  text_of(u))

function parse_update!(out, st, u::ToolCallNotif)
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    tc = build_tool_call(u)
    put!(out, tc)
    is_terminal(tc.status) ? close(tc) : (st.tools[tc.id] = tc)
    return nothing
end

# Late rawInput/name: claude-agent-acp STREAMS tool input, so the initial
# `tool_call` frequently arrives with an empty (or partial) `rawInput`; the
# complete arguments ride a later `tool_call_update`. Merge them into the
# tracked call so snapshot consumers (BonitoAgents's code preview, timeout
# badge, path hints, the taskbar's background flag) see the real arguments
# instead of the empty stub. `GenericTool`/`MCPCall` keep the raw dict; the
# typed variants re-extract the fields they pulled out at build time.
merge_late_input!(::ToolCall, ::AbstractDict) = nothing
merge_late_input!(tc::GenericTool, ri::AbstractDict) = (merge!(tc.raw_input, ri); nothing)
merge_late_input!(tc::MCPCall,     ri::AbstractDict) = (merge!(tc.raw_input, ri); nothing)
function merge_late_input!(tc::BashCall, ri::AbstractDict)
    haskey(ri, "command") && (tc.command = String(ri["command"]))
    haskey(ri, "run_in_background") &&
        (tc.run_in_background = ri["run_in_background"] === true)
    haskey(ri, "description") && (tc.description = _opt_str(ri["description"]))
    return nothing
end
function merge_late_input!(tc::TaskCall, ri::AbstractDict)
    haskey(ri, "description") && (tc.description = String(ri["description"]))
    haskey(ri, "prompt")      && (tc.prompt      = String(ri["prompt"]))
    haskey(ri, "run_in_background") &&
        (tc.run_in_background = ri["run_in_background"] === true)
    haskey(ri, "name") && (tc.task_name = _opt_str(ri["name"]))
    return nothing
end

function parse_update!(out, st, u::ToolCallUpdateNotif)   # routed by id; never touches the text bubble
    tc = get(st.tools, u.tool_call_id, nothing)
    tc === nothing && return nothing
    u.status !== nothing && (tc.status = u.status)
    u.title  !== nothing && (tc.title  = u.title)
    u.raw_input === nothing || merge_late_input!(tc, u.raw_input)
    u.tool_name === nothing || !(tc isa GenericTool) || (tc.name = u.tool_name)
    isempty(u.content) || (tc.content = Vector{ToolContent}(u.content))
    # Async subagent: the `async_launched` update carries the transcript
    # `outputFile` in `_meta.claudeCode.toolResponse` — the only deterministic
    # completion signal (the tool_call itself is `completed` at launch). Capture
    # it onto the TaskCall so the snapshot below hands it downstream BEFORE the
    # launch-ack `completed` closes the tool.
    if tc isa TaskCall && isempty(tc.output_file)
        of = async_output_file(u.raw)
        of === nothing || (tc.output_file = of)
    end
    push_snapshot!(tc.updates, tc)
    is_terminal(tc.status) && (close(tc); delete!(st.tools, tc.id))
    return nothing
end

function parse_update!(out, st, u::PlanUpdate)
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    put!(out, Plan(u.entries))
    return nothing
end

# Config/mode changes are session metadata, not turn content — deliver them
# WITHOUT closing the currently-streaming text bubble (unlike tools/plans,
# which are content boundaries).
parse_update!(out, st, u::ConfigOptionUpdateNotif) = (put!(out, ConfigUpdate(u.options)); nothing)
parse_update!(out, st, u::CurrentModeUpdateNotif)  = (put!(out, ModeUpdate(u.mode_id)); nothing)
parse_update!(out, st, u::UsageUpdateNotif) =
    (put!(out, UsageUpdate(u.used, u.size, u.cost_amount, u.cost_currency, u.origin_kind)); nothing)
parse_update!(out, st, u::AvailableCommandsUpdateNotif) =
    (put!(out, CommandsUpdate(u.commands)); nothing)

# Subagent-tagged updates: NEVER coalesced into the main stream (no
# current_message touch, no st.tools entry, nothing put! on `out`) — that
# interleaving is exactly the bug this arm exists to prevent. Distill the
# update into a `SubagentActivity` and hand it to the turn's sink; without a
# sink (or for update kinds that carry no feed signal — plans, config, user
# echoes) the update is dropped.
function parse_update!(out, st, u::SubagentUpdate)
    act = subagent_activity(u.parent_tool_use_id, u.update)
    if act === nothing || st.on_subagent === nothing
        @debug "ACP: dropping subagent update (no sink / no feed signal)" parent_tool_use_id = u.parent_tool_use_id typeof(u.update)
        return nothing
    end
    st.on_subagent(act)
    return nothing
end

# What a subagent update contributes to its parent's activity feed. Text /
# thought chunks carry their text; tool notifications the tool's title +
# status. Everything else (plan, config/mode, user echo, unknown) is `nothing`.
function subagent_activity(pid::String, u::Union{AgentMessageChunk,AgentThoughtChunk})
    t = text_of(u)
    t === nothing || isempty(t) ? nothing :
        SubagentActivity(pid, u isa AgentThoughtChunk ? :thought : :text, "", t, "")
end
subagent_activity(pid::String, u::ToolCallNotif) =
    SubagentActivity(pid, :tool, u.tool_call_id, u.title, u.status)
subagent_activity(pid::String, u::ToolCallUpdateNotif) =
    SubagentActivity(pid, :tool, u.tool_call_id,
                     something(u.title, ""), something(u.status, ""))
subagent_activity(::String, ::SessionUpdate) = nothing

parse_update!(::Any, ::Any, ::SessionUpdate) = nothing   # UnknownUpdate: ignore, don't disturb the stream

# Extend the open message if it's the same kind; else finish it and open a new one.
function text!(out, st, ::Type{T}, text) where {T<:Message}
    text === nothing && return nothing               # non-text / empty replay thought
    if st.current_message isa T
        # Steering-handoff duplicate (claude-agent-acp 0.44.0): text that
        # streamed while the PREVIOUS prompt's loop was still active gets
        # re-forwarded as one assembled block by the next prompt's loop (its
        # stream-dedup sets are per-loop). Shape: a single chunk that equals
        # EVERYTHING this message already received — drop it. (Observed live:
        # chunks "", "HELLO", then a duplicate "HELLO".)
        text == st.acc && !isempty(st.acc) && return nothing
        append!(st.current_message, text)
        st.acc *= text
    else
        st.current_message === nothing || close(st.current_message)
        st.current_message = T(text)
        st.acc = String(text)
        put!(out, st.current_message)                # delivered seeded with the first chunk
    end
    return nothing
end
