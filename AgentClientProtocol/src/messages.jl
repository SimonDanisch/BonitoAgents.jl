# Whole, ordered messages coalesced from the raw `session/update` soup.
#
# The dispatcher feeds one turn's `SessionUpdate`s into a channel; `prompt!`
# runs a bounded loop that turns them into clean `Message`s. A streaming message
# (agent text, thought, user echo, a tool call) carries its own `MessageStream`,
# closed at the message boundary. The wire-parse types (`AgentMessageChunk`,
# `ToolCallNotif`, …) never escape this file.

const ToolContent = Union{TextContent, DiffContent, ImageContent, ResourceLink}

"""
    MessageStream{T}

Where one message's streamed content lives — on the wire, on screen, and on disk.

A producer pushes items in with `put!`. ONE pump task, created WITH the stream so
a stream without a consumer cannot exist, folds each item into `items`. That
vector is the message's STATE: what a renderer draws, what gets persisted, and
what a message restored from disk is rebuilt with (`MessageStream(items)`).

`fold!` says how an item joins that state, and it is the only thing that differs
between message kinds — text deltas accumulate, while a `ToolCall` is one object
the parser mutates in place, so its newest snapshot replaces the previous one.

Two failure modes of the bare `updates::Channel` this replaces, both seen in
production:

  • An unread channel wedged its producer. `session/load` replay renders nothing,
    so every message type needed a hand-written `drain_message!` method purely to
    empty the channel, and the three that were never written took the whole
    resume down with `MethodError: no method matching
    drain_message!(::SessionNotice)` — a silent fall back to a fresh session.

  • Reading it cost a blocked task. A consumer sat in `for x in channel` until the
    message ended, so ONE open tool call parked the chat's single renderer for as
    long as that tool ran, and everything the agent said meanwhile showed up only
    once it finished.

Consumers either subscribe to `items` (a late subscriber — a second browser tab,
a re-render, a resumed session — reads the state it already holds instead of
having missed the deltas) or walk it with [`each_update`].
"""
struct MessageStream{T}
    inbox::Channel{T}
    items::Observable{Vector{T}}
    # Bumped by every fold. A consumer cannot use `length(items)` for this: a
    # latest-wins fold REPLACES, so the vector's length never moves and a
    # cursor-only reader would see the first snapshot and nothing after it.
    version::Base.RefValue{Int}
    # Set after every fold and once more when the stream ends, so a task-style
    # consumer can wait for progress. Auto-reset, and the consumer re-reads the
    # state after waking, so a notify landing between its check and its `wait` is
    # not a lost wakeup.
    ready::Base.Event
    pump::Task
end

# Fold one item into the state and tell everyone: subscribers through `items`,
# `each_update` walkers through `ready`. The single place `version` moves.
function fold_item!(s::MessageStream, item)
    fold!(s.items[], item)
    s.version[] += 1
    notify(s.items)
    notify(s.ready)
    return s
end

# How an arriving item joins the message's state.
fold!(items::Vector, item) = push!(items, item)

function MessageStream{T}(; buffer::Int = BUF) where {T}
    inbox  = Channel{T}(buffer)
    stream = MessageStream{T}(inbox, Observable(T[]), Ref(0), Base.Event(true),
                              @task nothing)
    pump = Base.errormonitor(@async begin
        try
            for item in inbox
                fold_item!(stream, item)
            end
        finally
            notify(stream.ready)   # release anyone waiting on a stream that ended
        end
    end)
    return MessageStream{T}(inbox, stream.items, stream.version, stream.ready, pump)
end

"""
    MessageStream(items::Vector{T})

A stream that is already complete — restored from disk, or built by a test. Its
inbox is closed, so a `put!` onto it raises instead of vanishing.
"""
function MessageStream(items::Vector{T}) where {T}
    inbox = Channel{T}(1)
    close(inbox)
    ready = Base.Event(true)
    pump  = Base.errormonitor(@async (for _ in inbox; end; notify(ready)))
    return MessageStream{T}(inbox, Observable(items), Ref(length(items)), ready, pump)
end

Base.put!(s::MessageStream{T}, item) where {T} = (put!(s.inbox, convert(T, item)); s)
Base.close(s::MessageStream)  = close(s.inbox)
Base.isopen(s::MessageStream) = isopen(s.inbox)
# Returns once every item the producer sent has been folded — i.e. after `close`,
# when the pump has drained what it still held.
Base.wait(s::MessageStream)   = wait(s.pump)
isdone(s::MessageStream)      = istaskdone(s.pump)

# What a consumer is handed when the state moves. An accumulating stream owes it
# every item it has not seen; a latest-wins stream owes it the current one, which
# is the whole state. Returns the new cursor.
function deliver(f, items::Vector, cursor::Int)
    for i in (cursor + 1):length(items)
        f(items[i])
    end
    return length(items)
end

"""
    each_update(f, s::MessageStream; from::Int = 0)

Call `f` with each update as it lands, on the CALLER's task, returning once the
stream is complete. The replacement for `for x in m.updates`: it walks the
message's STATE instead of consuming a channel, so it can be called late (it
catches up), called twice, and called by two consumers at once.

`from` is how much of an accumulating stream the caller has already rendered —
a bubble built from `text(m, n)` passes `n`, or it would print those items a
second time.
"""
function each_update(f, s::MessageStream; from::Int = 0)
    cursor = from
    seen   = -1                       # force one delivery of the current state
    while true
        version = s.version[]
        if version != seen
            seen   = version
            cursor = deliver(f, s.items[], cursor)
        elseif isdone(s)
            return nothing
        else
            wait(s.ready)
        end
    end
end

"""
    StreamingMessage <: Message

A message that arrives in pieces and therefore owns a [`MessageStream`]. The
hierarchy is the contract: a `StreamingMessage` has a `stream` field, anything
else under `Message` (a plan, a config/mode/usage/commands update, a session
notice) is complete the moment it is built. Code that has to treat the two
differently — replay waiting for completion, a renderer subscribing — dispatches
on this instead of listing types, which is what the old `drain_message!` did and
kept getting wrong.
"""
abstract type StreamingMessage <: Message end

# Complete once the pump has folded everything the producer sent.
Base.wait(m::StreamingMessage) = wait(m.stream)
isdone(m::StreamingMessage)    = isdone(m.stream)
each_update(f, m::StreamingMessage; from::Int = 0) = each_update(f, m.stream; from)

# A text message's content is its stream's items: the first chunk, then every
# delta. There is no separate `text` field to keep in sync — `text(m)` reads the
# state, which is as true for a message still streaming as for one replayed from
# `session/load` or read back from disk.
struct AgentMessage <: StreamingMessage
    stream::MessageStream{String}
end
struct Thought <: StreamingMessage
    stream::MessageStream{String}
end
struct UserMessage <: StreamingMessage
    stream::MessageStream{String}
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
abstract type ToolCall <: StreamingMessage end

# A `ToolCall` is ONE object, mutated in place by the parser: every push is the
# same call at a later status, so the newest IS the whole state. (This is what
# the old `push_snapshot!` drop-oldest `put!` was working around — it existed
# only because nothing guaranteed the channel had a reader.)
fold!(items::Vector{<:ToolCall}, tc::ToolCall) = (empty!(items); push!(items, tc))

# …and a consumer of one is owed the current call, not a list of the same object.
deliver(f, items::Vector{<:ToolCall}, cursor::Int) =
    (isempty(items) || f(items[end]); cursor + 1)



# Every concrete variant declares the same five header fields + `stream`,
# either via Composition (header struct field) or by direct duplication.
# Direct duplication wins on dispatch transparency: `tc.kind` and `tc.status`
# Just Work without `getproperty` overrides.

mutable struct GenericTool <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    stream::MessageStream{ToolCall}
    name::String                       # actual tool name from `_meta.claudeCode.toolName`
    raw_input::Dict{String,Any}
end

mutable struct BashCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    stream::MessageStream{ToolCall}
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
    stream::MessageStream{ToolCall}
    entries::Vector{PlanEntry}
end

mutable struct TaskCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    stream::MessageStream{ToolCall}
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
    stream::MessageStream{ToolCall}
    server::String                     # "bonitoagents"
    tool_name::String                  # bare name without `mcp__server__` prefix
    raw_input::Dict{String,Any}
end

struct Plan <: Message
    entries::Vector{PlanEntry}
    # False = this plan's stream is over; it will never be updated again.
    #
    # The protocol has no "plan ended" frame: the agent resends the whole entry
    # list, and each ENTRY carries pending/in_progress/completed. That is enough
    # for a plan the agent finishes (every entry completed) but says nothing
    # about one it ABANDONS — the turn is cancelled, the agent dies, the worker
    # goes away — and an abandoned plan's entries simply stay where they were.
    # A consumer with only the entries to go on cannot tell "still working on
    # 0/4" from "stopped, having done 0/4", so it shows it as live forever
    # (observed: todo pills counting past 35 hours).
    #
    # This is the STREAM's answer, and `close_turn!` is the single place it is
    # given — the same one that force-fails live tools, on the same events. It is
    # not the only way a plan ends (an agent that works its entries to terminal
    # ends it by status, and an episode that simply STOPS is visible to a
    # consumer as `session_activity` — neither needs a frame). It is the one that
    # covers a stream dying under a live plan, which nothing else can see.
    #
    # The entries are left EXACTLY as the agent last reported them: sealing is a
    # property of the plan, not a status we forge onto its entries. Tools get
    # `failed` here because the protocol HAS that status for a tool; plan entries
    # have no equivalent, and inventing one would misreport what the agent said.
    live::Bool
end
Plan(entries::Vector{PlanEntry}) = Plan(entries, true)

# Session-config changes mid-turn. Metadata, not content: they don't open a
# bubble and don't close the currently-streaming message.
struct ConfigUpdate <: Message
    options::Vector{ConfigOption}        # complete updated state (spec)
end
struct SessionNotice <: Message
    record::Dict{String,Any}
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

# A fresh streaming message, seeded with its first chunk. The seed is folded
# SYNCHRONOUSLY rather than sent through the inbox: a reader that looks the
# instant the message is constructed (`to_message` does) must see the first
# chunk, not race the pump for it.
function seeded_stream(t::AbstractString)
    s = MessageStream{String}()
    fold_item!(s, String(t))
    return s
end
AgentMessage(t::AbstractString) = AgentMessage(seeded_stream(t))
Thought(t::AbstractString)      = Thought(seeded_stream(t))
UserMessage(t::AbstractString)  = UserMessage(seeded_stream(t))

"""
    text(m) -> String

Everything this message has said so far. While it streams this grows; once the
stream ends it is final.
"""
text(m::Union{AgentMessage,Thought,UserMessage}) = join(m.stream.items[])

"""
    text(m, upto::Integer) -> String

The first `upto` chunks only. A renderer commits a bubble with this and then
streams the rest from the same cursor, so no chunk is drawn twice however many
arrived while it was committing.
"""
text(m::Union{AgentMessage,Thought,UserMessage}, upto::Integer) =
    join(view(m.stream.items[], 1:min(upto, length(m.stream.items[]))))

# Closing a message closes its own stream. The ToolCall arm is one method that
# covers every concrete variant (GenericTool / BashCall / TodoWriteCall / …)
# because they all share the `stream::MessageStream{ToolCall}` field.
Base.close(m::AgentMessage) = close(m.stream)
Base.close(m::Thought)      = close(m.stream)
Base.close(m::UserMessage)  = close(m.stream)
Base.close(m::ToolCall)     = close(m.stream)

# Appending a chunk feeds the message's stream.
Base.append!(m::AgentMessage, t::AbstractString) = (put!(m.stream, String(t)); m)
Base.append!(m::Thought, t::AbstractString)      = (put!(m.stream, String(t)); m)
Base.append!(m::UserMessage, t::AbstractString)  = (put!(m.stream, String(t)); m)

# (`drain_message!` used to live here: one method per message type, whose only
# job was to empty a channel nobody was reading so the producer could keep going.
# A message now folds its own stream, so there is nothing to drain and no list of
# types to keep in sync — the three that were missing from it took down every
# `session/load` that replayed one.)

# Same question as `is_agent_work(::SessionUpdate)`, asked of a coalesced
# message: is this the agent DOING something, or telling us about the session?
#
# A renderer reads it to decide whether an AUTO-WAKE EPISODE has begun — the
# agent talking with no prompt open. Session metadata (config/mode/usage/
# commands) arrives on bind and at turn boundaries, so counting it would open an
# episode on a chat that has done nothing.
is_agent_work(::Message)        = true
is_agent_work(::ConfigUpdate)   = false
is_agent_work(::ModeUpdate)     = false
is_agent_work(::UsageUpdate)    = false
is_agent_work(::CommandsUpdate) = false
is_agent_work(::StreamFlush)    = false


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
        Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
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
        Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
        entries,
    )
end

# Claude Code calls its subagent tool `Task` (legacy) and `Agent` (newer SDK).
# Both carry the same shape; we treat them identically.
for sdk_name in (:Task, :Agent)
    @eval function build_tool_call(::Val{$(QuoteNode(sdk_name))}, n::ToolCallNotif)
        return TaskCall(
            n.tool_call_id, n.kind, n.title, n.status,
            Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
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
                Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
                server, tname,
                n.raw_input,
            )
        end
    end
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
        s, n.raw_input,
    )
end

# Fallback when claude-agent-acp didn't fill the meta (`tool_name == ""`):
# we have no name to dispatch on, so the call lands as `GenericTool` with an
# empty name. UX will show the ACP `kind` + `title` like before.
#
# …with one exception. codex-acp names NO tool — not in `_meta`, not in the
# title (its shell title IS the command line, spaces and all) — so a shell call
# from it would render as a nameless generic pill with the command only in the
# heading and no command line in the card. An `execute` kind carrying a
# `command` string is unambiguously a shell call whatever produced it, so route
# it to `BashCall` on that shape. Every agent that DOES name the tool ("Bash")
# dispatches above and never reaches here.
function build_tool_call(::Val{Symbol("")}, n::ToolCallNotif)
    cmd = get(n.raw_input, "command", nothing)
    if n.kind == "execute" && cmd isa AbstractString && !isempty(cmd)
        return BashCall(
            n.tool_call_id, n.kind, n.title, n.status,
            Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
            String(cmd),
            get(n.raw_input, "run_in_background", false) === true,
            _opt_str(get(n.raw_input, "description", nothing)),
        )
    end
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), MessageStream{ToolCall}(),
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
            stream::MessageStream = MessageStream{ToolCall}()) =
    GenericTool(String(id), String(kind), String(title), String(status),
                Vector{ToolContent}(content), stream,
                "", Dict{String,Any}())

# ── Subagent activity ────────────────────────────────────────────────────────
# One subagent event, distilled from a `SubagentUpdate` for the subagent that
# owns it. NOT a `Message`: it never travels the main thread's message channel —
# that consumer can be parked inside a long-running tool's snapshot drain (often
# the very Task tool the subagent belongs to), which would starve the feed of
# exactly the live updates it exists to show. Built straight from the addressed
# update by the owner's consumer; see `subagent_activity`.
struct SubagentActivity
    parent_id::String    # the parent Task's tool_use id
    kind::Symbol         # :text | :thought | :tool
    tool_id::String      # subagent tool_call id; "" for text/thought
    label::String        # chunk text, or the subagent tool's title
    status::String       # subagent tool status; "" for text/thought
end

# ── Stream parser ───────────────────────────────────────────────────────────
# The coalescing state of ONE update stream: the text message currently being
# streamed (if any) plus the set of tools still awaiting completion.
#
# A `TurnState` outlives any single turn — the main thread's stream is
# continuous, and `close` is a BOUNDARY on it (end of prompt, start of the
# next), not the end of its life. So `close` leaves the state clean and
# reusable rather than spent.
mutable struct TurnState
    current_message::Union{Message,Nothing}
    tools::Dict{String,ToolCall}
    # Everything the current text message has received so far — used by
    # `text!` to drop claude-agent-acp's handoff duplicate (see there).
    acc::String
    # The last plan the agent sent, or `nothing` once it has been sealed. Held
    # for the same reason `tools` is: it is a LIVE thing the stream can end in
    # the middle of, and whatever ends the stream has to finish it. The agent
    # always resends the whole list, so last-one-wins is the whole state.
    plan::Union{Vector{PlanEntry},Nothing}
end
TurnState() = TurnState(nothing, Dict{String,ToolCall}(), "", nothing)

# Closing the stream at a boundary finishes the trailing message and any
# still-open tools, and leaves the state ready for what comes next.
#
# Any tool still in `st.tools` is one the agent NEVER reported terminal for —
# the turn ended (cancel, EOF, peer hang-up) before its `tool_call_update` with
# a completed/failed status arrived. Force it to `"failed"` and push ONE final
# snapshot through its `updates` channel BEFORE closing, so downstream consumers
# (BonitoAgents's `process_update!`) see a terminal status and finalize naturally —
# instead of draining a channel that just-closed with the status frozen mid-flight.
# Seal the trailing TEXT message at a boundary — and NOTHING else.
#
# A boundary is not the end of the stream. A tool call routinely spans one: an
# eval runs for minutes while you send another message, and `begin_turn` puts a
# marker on the stream before it prompts. `close` force-fails every live tool
# and empties `st.tools`, so past that point every `tool_call_update` for the
# running eval finds no tool and is dropped — its card freezes at `in_progress`
# with an empty CODE and OUTPUT while the eval is still going.
#
# Tools the agent genuinely abandons are not lost by leaving them here: the chat
# layer closes each bubble in its drain `finally`,
# and it deliberately runs only for the LAST turn precisely so a handoff doesn't
# force-fail its successor's live tools.
function seal_message!(st::TurnState)
    st.current_message === nothing || close(st.current_message)
    st.current_message = nothing
    st.acc = ""            # the handoff-duplicate window ends with the message
    return nothing
end

# Finish EVERYTHING the stream can end in the middle of. Takes `out` (rather
# than being a `close(st)` you can call anywhere) on purpose: sealing the plan
# needs the main stream, and a one-argument version would be a second door that
# a future caller could walk through while forgetting the plan — which is how
# plans came to outlive their episodes in the first place.
function close_turn!(out::Channel, st::TurnState)
    seal_message!(st)
    for tc in values(st.tools)
        if !is_terminal(tc.status)
            # This is the ONLY place a tool becomes "failed" without the agent
            # saying so, and the badge it produces is indistinguishable from a
            # real failure. Say it out loud: three subagent cards once showed
            # `failed` for reviews the wire had reported `completed`, and the
            # only way to tell whether that came from here (a tool still open
            # at end-of-turn) or from the update path (a completed status that
            # never landed) was to diff the transcript against acp.jsonl by
            # hand. Now the server log answers it.
            @warn "ACP: tool still open at end of turn, marking it failed" tool_id = tc.id title = tc.title last_status = tc.status
            tc.status = "failed"
            put!(tc.stream, tc)
        end
        close(tc)
    end
    empty!(st.tools)
    if st.plan !== nothing
        entries = st.plan
        st.plan = nothing
        # Bounded channel, so this CAN block if the consumer stopped draining —
        # the same exposure every `put!(out, …)` in the parse loop already has,
        # and reaching here means the loop was draining until a moment ago. Not
        # risk-free, but the alternative (dropping the seal) is the bug.
        isopen(out) && put!(out, Plan(entries, false))
    end
    return nothing
end

is_terminal(status::AbstractString) = status in ("completed", "failed")

# (`push_snapshot!` used to live here: a drop-oldest `put!` for tool snapshots,
# because a UI consumer that abandoned its channel would otherwise fill the
# buffer, block the per-turn parse loop and wedge the whole turn. A
# `MessageStream` has a pump that always drains and a `fold!` that keeps only the
# newest snapshot, so a plain `put!(tc.stream, tc)` is now both unblockable and
# lossless for the state.)

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

# Do we already know this call's arguments? Each variant answers for the field
# it would actually show, so the streamed-input recovery below stays dormant the
# moment real arguments exist — which for claude-agent-acp is immediately, since
# it always sends them in `rawInput`.
input_known(::ToolCall)         = true
input_known(tc::GenericTool)    = !isempty(tc.raw_input)
input_known(tc::MCPCall)        = !isempty(tc.raw_input)
input_known(tc::BashCall)       = !isempty(tc.command)
input_known(tc::TaskCall)       = !isempty(tc.prompt)
input_known(tc::TodoWriteCall)  = !isempty(tc.entries)

"""
    streamed_input_text(tc, u) -> String or nothing

The text of a `tool_call_update` that is the agent STREAMING this call's
arguments rather than reporting output, or `nothing` when the frame is ordinary
content.

Deliberately narrow, so an agent that reports output normally is never
misread: it fires only when the frame carries no `rawInput` of its own, the
call still has NO arguments at all, the frame is non-terminal, and its content
is exactly one text block that opens a JSON object. claude-agent-acp always
puts arguments in `rawInput`, so `input_known` is already true by the time any
content arrives and this path stays dormant for it.
"""
function streamed_input_text(tc::ToolCall, u::ToolCallUpdateNotif)
    u.raw_input === nothing || return nothing
    input_known(tc) && return nothing
    is_terminal(something(u.status, tc.status)) && return nothing
    length(u.content) == 1 || return nothing
    c = u.content[1]
    c isa TextContent || return nothing
    t = lstrip(c.text)
    return startswith(t, "{") ? String(t) : nothing
end

# The streamed argument text is a complete JSON object only on the LAST
# non-terminal frame; every earlier prefix is a parse error, which is the
# expected steady state here and not something to report.
function parse_json_object(s::AbstractString)
    v = try
        JSON.parse(s)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    return v isa AbstractDict ? Dict{String,Any}(String(k) => x for (k, x) in v) : nothing
end

function parse_update!(out, st, u::ToolCallUpdateNotif)   # routed by id; never touches the text bubble
    tc = get(st.tools, u.tool_call_id, nothing)
    tc === nothing && return nothing
    u.status !== nothing && (tc.status = u.status)
    u.title  !== nothing && (tc.title  = u.title)
    u.raw_input === nothing || merge_late_input!(tc, u.raw_input)
    u.tool_name === nothing || !(tc isa GenericTool) || (tc.name = u.tool_name)
    # Agents that never send `rawInput` stream the tool's ARGUMENTS as content
    # text instead (verified against kimi 0.29.2: 14 non-terminal frames going
    # `{"code":"` → `{"code":"1` → … → the complete argument object, then one
    # terminal frame whose content is the real result). Taking those at face
    # value renders half-typed argument JSON as the tool's OUTPUT and leaves the
    # arguments unknown — an eval card with a flickering Output pane and an
    # empty Code box. Route them to the input instead, and don't let them
    # overwrite content. See `streamed_input_text`.
    args_text = streamed_input_text(tc, u)
    if args_text === nothing
        isempty(u.content) || (tc.content = Vector{ToolContent}(u.content))
    else
        parsed = parse_json_object(args_text)
        parsed === nothing || merge_late_input!(tc, parsed)
    end
    # Async subagent: the `async_launched` update carries the transcript
    # `outputFile` in `_meta.claudeCode.toolResponse` — the only deterministic
    # completion signal (the tool_call itself is `completed` at launch). Capture
    # it onto the TaskCall so the snapshot below hands it downstream BEFORE the
    # launch-ack `completed` closes the tool.
    if tc isa TaskCall && isempty(tc.output_file)
        of = async_output_file(u.raw)
        of === nothing || (tc.output_file = of)
    end
    put!(tc.stream, tc)
    is_terminal(tc.status) && (close(tc); delete!(st.tools, tc.id))
    return nothing
end

function parse_update!(out, st, u::PlanUpdate)
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    # Remember it, so whatever ends the stream can seal it. The agent resends
    # the whole list every time, so the newest one is the state.
    st.plan = u.entries
    put!(out, Plan(u.entries))
    return nothing
end

# Config/mode changes are session metadata, not turn content — deliver them
# WITHOUT closing the currently-streaming text bubble (unlike tools/plans,
# which are content boundaries).
parse_update!(out, st, u::ConfigOptionUpdateNotif) = (put!(out, ConfigUpdate(u.options)); nothing)
function parse_update!(out, st, u::SessionNoticeNotif)
    # Release a streaming text consumer so a retry notice is visible while the
    # provider is stalled, rather than waiting for the end of its answer.
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    put!(out, SessionNotice(u.record))
    return nothing
end
parse_update!(out, st, u::CurrentModeUpdateNotif)  = (put!(out, ModeUpdate(u.mode_id)); nothing)
parse_update!(out, st, u::UsageUpdateNotif) =
    (put!(out, UsageUpdate(u.used, u.size, u.cost_amount, u.cost_currency, u.origin_kind)); nothing)
parse_update!(out, st, u::AvailableCommandsUpdateNotif) =
    (put!(out, CommandsUpdate(u.commands)); nothing)

# Subagent-tagged updates never reach a main-thread coalescer: the dispatcher
# addresses them to their owner before any stream logic runs. This arm exists
# for the one path that still feeds raw updates through a parser directly — a
# `session/load` replay, whose captured stream can contain subagent-tagged
# frames from the recorded history. They are not the live conversation and have
# no owner to belong to (the replay predates every message), so drop them here
# rather than let them interleave into the resumed transcript.
function parse_update!(out, st, u::SubagentUpdate)
    @debug "ACP: dropping replayed subagent update" parent_tool_use_id = u.parent_tool_use_id typeof(u.update)
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
