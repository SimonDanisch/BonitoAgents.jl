# ── A history replay, cut to its tail ─────────────────────────────────────────
# When a chat resumes, its agent replays the whole session (`session/load`), and
# the server uses that only to find messages its own record of the chat is
# missing. On a slow uplink the replay saturated the worker's one connection to
# the server: a laptop's 3591 messages with images (11-27) held up every other
# request for over ten minutes, and the chat sat "busy" with no session.
#
# The replay reaches the worker over the agent's stdout, which costs nothing;
# only the hop to the server does. So when the server asks for a tail
# (`_meta["bonito/replayTail"] = N` on its `session/load`), the worker keeps the
# last N messages of the replay, sends those, then the load's answer. The
# server's reconciler anchors on its own newest messages inside the tail, and
# loads the whole replay when they are not in it.
#
# Every agent replays the same way, as ACP `session/update`s, so this knows
# nothing about any agent's own files. Updates that are not part of a message
# (modes, commands, usage, titles) are small and always sent.

# One frame of a replay being cut: the line as the agent sent it, and the
# message it belongs to (0: not part of a message, always sent).
struct CutFrame
    line::String
    message::Int
end

# The load being cut, from its `session/load` to its answer. One per agent
# session; both relay directions share it.
mutable struct ReplayCut
    lock::ReentrantLock
    request_id::Any             # the load's JSON-RPC id; `nothing` while no load is cut
    session_id::String
    keep::Int                   # how many of the last messages to send
    frames::Vector{CutFrame}    # held back, in arrival order
    messages::Int               # messages started so far
    last_chunk::String          # the kind of the previous main-thread chunk, "" after anything else
    owner::Dict{String,Int}     # toolCallId → the message it belongs to
    trim_at::Int                # drop what can no longer be in the tail once this many frames are held
end

ReplayCut() = ReplayCut(ReentrantLock(), nothing, "", 0, CutFrame[], 0, "", Dict{String,Int}(), 1024)

const CHUNK_KINDS = ("user_message_chunk", "agent_message_chunk", "agent_thought_chunk")

# The server's `session/load`, on its way to the agent: start holding its replay
# back if it asks for a tail.
function note_replay_load!(cut::ReplayCut, line::AbstractString)
    occursin("bonito/replayTail", line) || return nothing
    msg = JSON.parse(line)
    (msg isa AbstractDict && get(msg, "method", nothing) == "session/load") || return nothing
    params = get(msg, "params", nothing)
    params isa AbstractDict || return nothing
    meta = get(params, "_meta", nothing)
    keep = meta isa AbstractDict ? get(meta, "bonito/replayTail", nothing) : nothing
    (keep isa Integer && keep > 0) || return nothing
    @lock cut.lock begin
        cut.request_id = get(msg, "id", nothing)
        cut.session_id = String(get(params, "sessionId", ""))
        cut.keep       = Int(keep)
        empty!(cut.frames); empty!(cut.owner)
        cut.messages   = 0
        cut.last_chunk = ""
        cut.trim_at    = 1024
    end
    return nothing
end

# A line from the agent, on its way to the server: held back while it is part of
# a replay being cut, else sent. The load's answer sends the tail, then itself.
function forward_agent_line!(cut::ReplayCut, ch, line::AbstractString)
    (@lock cut.lock cut.request_id !== nothing) || return WebSockets.send(ch, line)
    msg = try
        JSON.parse(line)
    catch e
        # Not JSON: not ours to judge. It goes on as it came.
        e isa ArgumentError || rethrow()
        return WebSockets.send(ch, line)
    end
    out = @lock cut.lock begin
        if !(msg isa AbstractDict) || cut.request_id === nothing
            String[line]
        elseif !haskey(msg, "method") && get(msg, "id", nothing) == cut.request_id
            lines = tail!(cut)
            push!(lines, String(line))
            cut.request_id = nothing
            lines
        elseif get(msg, "method", nothing) == "session/update" &&
               get(get(msg, "params", Dict{String,Any}()), "sessionId", nothing) == cut.session_id
            hold!(cut, line, get(msg["params"], "update", Dict{String,Any}()))
            String[]
        else
            String[line]
        end
    end
    foreach(l -> WebSockets.send(ch, l), out)
    return nothing
end

# The tool call a subagent's update belongs to (claude-agent-acp's
# `_meta.claudeCode.parentToolUseId`), or `nothing`.
function parent_tool(u::AbstractDict)
    meta = get(u, "_meta", nothing)
    meta isa AbstractDict || return nothing
    cc = get(meta, "claudeCode", nothing)
    cc isa AbstractDict || return nothing
    p = get(cc, "parentToolUseId", nothing)
    return p isa AbstractString ? String(p) : nothing
end

# Hold one replayed update back, numbered by the message it belongs to.
# Consecutive chunks of one kind are one message; a tool call is one, with its
# updates and its subagent's frames; a plan is one.
function hold!(cut::ReplayCut, line::AbstractString, u::AbstractDict)
    kind = String(get(u, "sessionUpdate", ""))
    id   = get(u, "toolCallId", nothing)
    id   = id isa AbstractString ? String(id) : nothing
    parent = parent_tool(u)
    m = if parent !== nothing
        k = get(cut.owner, parent, 0)
        id === nothing || (cut.owner[id] = k)
        k
    elseif kind in CHUNK_KINDS
        kind == cut.last_chunk ? cut.messages : (cut.messages += 1)
    elseif kind == "tool_call" || kind == "plan"
        cut.messages += 1
        id === nothing || (cut.owner[id] = cut.messages)
        cut.messages
    elseif kind == "tool_call_update"
        id === nothing ? 0 : get(cut.owner, id, 0)
    else
        0
    end
    # A subagent's frames and the small updates between messages don't end a
    # run of chunks; anything else of the main thread does.
    if parent === nothing && m != 0
        cut.last_chunk = kind in CHUNK_KINDS ? kind : ""
    end
    push!(cut.frames, CutFrame(String(line), m))
    if length(cut.frames) >= cut.trim_at
        below = cut.messages - cut.keep
        filter!(f -> f.message == 0 || f.message > below, cut.frames)
        cut.trim_at = 2 * length(cut.frames) + 1024
    end
    return nothing
end

# The frames to send: the last `keep` messages and every update that is not part
# of a message, in the order they came.
function tail!(cut::ReplayCut)
    below = cut.messages - cut.keep
    lines = String[f.line for f in cut.frames if f.message == 0 || f.message > below]
    empty!(cut.frames); empty!(cut.owner)
    return lines
end
