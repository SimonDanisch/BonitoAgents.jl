# `CM` is `import CommonMark as CM` in BonitoAgents.jl — hoisted so chat.jl's
# const CommonMark parser resolves at include time.

# Session metadata + file path
struct ChatSession
    session_id::String      # ACP session ID (for --resume)
    cwd::String             # project working dir (for claude --cwd / display)
    created::DateTime
    path::String            # absolute path to chat.md (server-state-managed)
    # Serializes all chat.md writes for this chat (appends vs the header
    # read-modify-write in `update_session_id!`). A FIELD, not a module-global
    # `Dict{path => lock}` pool. CARRIED across `update_session_id!` (which
    # rebuilds the session for the SAME path) so a path keeps one lock; per-session
    # views share it because they share the one ChatSession.
    write_lock::ReentrantLock
end
# Default the lock for the common 4-arg construction; update_session_id! passes
# the prior session's lock explicitly to keep it path-stable across the rebuild.
ChatSession(session_id, cwd, created, path) =
    ChatSession(session_id, cwd, created, path, ReentrantLock())

"""
    chat_storage_dir(state, project_id, cwd) -> String

Resolve the directory holding chat.md + tools/ for a project. Server-owned
state, lives alongside `workers.json` / `projects.json` under
`state.state_dir/chats/<project_id>/`. This deliberately sits OUTSIDE the
project tree so:

- Project sync never has to ignore it (the project tree is "code only")
- Project rename / move / re-sync to another worker can't lose chat history
- A worker without `.bonitoAgents` (which is every worker — chat is generated
  server-side from ACP events) can't accidentally clobber the server's
  chat by being the sync source

Legacy fallback `<cwd>/.bonitoAgents/` is kept for project_id-less callers
(tests, ad-hoc chats outside the project registry). A one-shot migration
`mv`s any pre-existing `<cwd>/.bonitoAgents/` into the new home the first
time a project loads under the new layout.
"""
function chat_storage_dir(state, project_id::AbstractString, cwd::AbstractString)
    if !isempty(project_id)
        new_dir = joinpath(state.state_dir, "chats", String(project_id))
        old_dir = joinpath(cwd, ".bonitoAgents")
        if isdir(old_dir) && !isdir(new_dir)
            mkpath(dirname(new_dir))
            try
                mv(old_dir, new_dir)
                @info "migrated chat storage to state_dir" project_id from=old_dir to=new_dir
            catch e
                # Cross-device mv fails on some setups; fall back to copy+rm.
                @warn "mv failed during chat-storage migration, copying" exception=e
                mkpath(new_dir)
                cp(old_dir, new_dir; force=true)
                rm(old_dir; recursive=true, force=true)
            end
        end
        mkpath(new_dir)
        return new_dir
    end
    # No project id: orphan chat, keep legacy in-tree storage.
    d = joinpath(cwd, ".bonitoAgents")
    mkpath(d)
    return d
end

session_file(chat_dir::AbstractString) = joinpath(String(chat_dir), "chat.md")

# Per-chat.md write lock (T13). chat.md is touched by two kinds of writer that
# must not interleave: append-only writers (`append_user`/`finalize_agent`/…)
# and the header read-modify-write (`update_session_id!`). Without a lock the
# RMW reads the whole file, then rewrites it — an append landing in that window
# is silently lost, and a crash mid-rewrite truncates the history. We serialize
# all chat.md writes for a chat through the lock carried on its `ChatSession`
# (`write_lock`) — one per chat, shared by every per-session view (they share the
# one session) and kept stable across `update_session_id!`. No module-global pool.
chat_file_lock(session::ChatSession) = session.write_lock

# ── ACP wire-frame log ──────────────────────────────────────────────────────
# Raw ACP JSON-RPC traffic (both directions), one envelope per line:
#   {"ts": "2026-06-05T12:34:56.789Z", "dir": "in"|"out", "msg": <frame>}
# Append-only, lives next to chat.md; served read-only via /acp-log/<pid>.

acp_log_file(chat_dir::AbstractString) = joinpath(String(chat_dir), "acp.jsonl")

"""
    acp_frame_logger(chat_dir) -> Function

Build an `on_frame` tap (see `AgentClientProtocol.Connection`) that appends
every ACP frame to `chat_dir/acp.jsonl`. Per-call open-append: frames are
low-rate (claude-agent-acp chunks are paragraph-sized), and holding no handle
means restarts / external deletion need no lifecycle handling. The lock
serializes the reader task (`:in`) against sender tasks (`:out`).
"""
function acp_frame_logger(chat_dir::AbstractString)
    path = acp_log_file(chat_dir)
    lk = ReentrantLock()
    return function (dir::Symbol, msg::AbstractDict)
        ts = Dates.format(now(UTC), dateformat"yyyy-mm-dd\THH:MM:SS.sss\Z")
        lock(lk) do
            open(path, "a") do io
                JSON.print(io, Dict{String,Any}(
                    "ts" => ts, "dir" => String(dir), "msg" => msg))
                println(io)
            end
        end
        return nothing
    end
end

# Per-tool JSON snapshot of the latest ACP params (the wire format itself), so
# tool bodies survive restarts and don't have to live in process memory.
function tools_dir(chat_dir::AbstractString)
    d = joinpath(String(chat_dir), "tools")
    mkpath(d)
    return d
end

tool_file(chat_dir::AbstractString, tool_id::AbstractString) =
    joinpath(tools_dir(chat_dir), String(tool_id) * ".json")

# Persist a tool's parsed content blocks so the lazily-loaded body survives
# restarts. We serialize the typed `Vector{ToolContent}` back to the same
# `{"content": [...]}` shape `load_tool_content` reads (the inverse of
# `parse_tool_content_item`) — no raw wire dict round-trips through the chat.
# Status-only updates carry no content, so there's nothing to persist.
tool_content_to_dict(c::DiffContent) = Dict{String,Any}(
    "type" => "diff", "path" => c.path, "oldText" => c.old_text, "newText" => c.new_text)
tool_content_to_dict(c::TextContent) = Dict{String,Any}(
    "type" => "content", "content" => Dict{String,Any}("type" => "text", "text" => c.text))
tool_content_to_dict(c::ImageContent) = Dict{String,Any}(
    "type" => "content", "content" => Dict{String,Any}(
        "type" => "image", "data" => c.data, "mimeType" => c.mime_type))

function persist_tool_content!(chat_dir::AbstractString, tc::AgentClientProtocol.ToolCall)
    isempty(tc.content) && return nothing
    path = tool_file(chat_dir, tc.id)
    d = Dict{String,Any}("content" => [tool_content_to_dict(c) for c in tc.content])
    # The call's arguments (for the variants that keep them): claude's
    # Read/Edit/Write carry the real `file_path` here — the ✎ editor
    # affordance needs it after a history reload, where the ToolMsg's
    # in-RAM raw_input is gone.
    ri = raw_input_of(tc)
    ri === nothing || isempty(ri) || (d["rawInput"] = ri)
    open(path, "w") do io
        JSON.print(io, d)
    end
    return nothing
end

raw_input_of(::AgentClientProtocol.ToolCall)      = nothing
raw_input_of(tc::AgentClientProtocol.GenericTool) = tc.raw_input
raw_input_of(tc::AgentClientProtocol.MCPCall)     = tc.raw_input
# BashCall extracts its typed fields at parse time and drops the dict —
# reconstruct the bits history reload needs (the description drives the
# pill title; the command feeds the tooltip).
raw_input_of(tc::AgentClientProtocol.BashCall) = Dict{String,Any}(
    "command" => tc.command,
    "run_in_background" => tc.run_in_background,
    (tc.description === nothing ? () : ("description" => tc.description,))...)

# The arguments recorded with the tool snapshot, for consumers running
# after a history reload (the ToolMsg's in-RAM fields are gone).
function stored_raw_input(chat_dir::AbstractString, tool_id::AbstractString)
    params = load_tool_file(String(chat_dir), String(tool_id))
    params === nothing && return nothing
    ri = get(params, "rawInput", nothing)
    return ri isa AbstractDict ? ri : nothing
end

# Path argument from the stored snapshot (rawInput.file_path / path / …) —
# feeds the path-link derivation after a history reload.
function stored_path_hint(chat_dir::AbstractString, tool_id::AbstractString)
    ri = stored_raw_input(chat_dir, tool_id)
    ri === nothing && return nothing
    return mcp_path_hint(ri)
end

function load_tool_file(chat_dir::AbstractString, tool_id::AbstractString)::Union{AbstractDict,Nothing}
    path = tool_file(chat_dir, tool_id)
    isfile(path) || return nothing
    return open(JSON.parse, path)
end

# Load or create a session. `chat_dir` is where chat.md lives (resolved via
# `chat_storage_dir`); `cwd` is the project's working dir (recorded on the
# ChatSession for display + claude resume).
function load_session(chat_dir::AbstractString, cwd::AbstractString)::ChatSession
    path = session_file(chat_dir)
    if isfile(path)
        session = parse_session_meta(path, String(cwd))
        session !== nothing && return session
    end
    # Create fresh session
    session = ChatSession("", String(cwd), now(UTC), path)
    write_session_header(session)
    return session
end

function parse_session_meta(path::String, cwd::String)::Union{ChatSession,Nothing}
    src = read(path, String)
    parser = CM.Parser()
    CM.enable!(parser, CM.FrontMatterRule(toml=TOML.parse))
    ast = parser(src)
    for (node, entering) in ast
        node.t isa CM.FrontMatter && entering || continue
        data = node.t.data
        sid  = get(data, "session_id", "")
        ts   = get(data, "created", string(now(UTC)))
        created = try DateTime(ts) catch; now(UTC) end
        return ChatSession(sid, cwd, created, path)
    end
    return nothing
end

# Atomic whole-file write of chat.md: serialize to a unique sibling temp then
# rename, so a crash mid-write can never truncate the chat history (T13). The
# caller holds `chat_file_lock(path)`.
function atomic_write_text(f, path::AbstractString)
    dir = dirname(String(path))
    mkpath(dir)
    tmp = tempname(dir; cleanup = false)
    try
        open(tmp, "w") do io
            f(io)
        end
        mv(tmp, String(path); force = true)
    catch
        try
            rm(tmp; force = true)
        catch cleanup_err
            @debug "atomic_write_text: could not remove temp file" tmp exception = cleanup_err
        end
        rethrow()
    end
end

# The `+++` TOML front-matter block every chat.md starts with (the inverse of
# `parse_session_meta`). Shared by the fresh-file, header-RMW and full-rewrite
# writers.
function print_front_matter(io::IO, session::ChatSession)
    println(io, "+++")
    println(io, "session_id = $(repr(session.session_id))")
    println(io, "cwd = $(repr(session.cwd))")
    println(io, "created = $(repr(string(session.created)))")
    println(io, "+++")
end

function write_session_header(session::ChatSession)
    lock(chat_file_lock(session)) do
        atomic_write_text(session.path) do io
            print_front_matter(io, session)
            println(io)
        end
    end
end

function update_session_id!(session::ChatSession, new_id::String)
    path = session.path
    # The read-modify-write runs under the per-file lock so an `append_*` can't
    # land between the read and the rewrite (lost append), and the write is
    # atomic (tmp + mv) so a crash can't truncate the file (T13).
    lock(chat_file_lock(session)) do
        content = isfile(path) ? read(path, String) : "\n"
        # Strip existing +++ block
        body = replace(content, r"^\+\+\+.*?\+\+\+\n"s => ""; count=1)
        # CARRY the same write_lock: this rebuilds the session for the SAME path,
        # so a concurrent writer (using the old or new session view) must take the
        # SAME lock — a fresh one would reopen the race this lock exists to close.
        new_session = ChatSession(new_id, session.cwd, session.created, path, session.write_lock)
        atomic_write_text(path) do io
            print_front_matter(io, new_session)
            print(io, body)
        end
    end
end

"""
    first_user_prompt(chat_dir) -> Union{String,Nothing}

Scan `chat.md` for the FIRST `!!! user "..."` admonition and return its body,
dedented. Returns `nothing` if the file doesn't exist, has no user message
yet, or the body is empty. Used by the Rescan sweep to re-derive project
titles from the original prompt instead of the once-saved (possibly stale)
`p.title` — relevant when an older `meaningful_title` had a bug and the
truncated/leaked title is now pinned on disk.
"""
function first_user_prompt(chat_dir::AbstractString)::Union{String,Nothing}
    path = session_file(chat_dir)
    isfile(path) || return nothing
    lines  = split(read(path, String), '\n')
    n      = length(lines)
    header = r"^!!! (\w+)(?:\s+\"(.*)\")?\s*$"

    i = 1
    # Skip the +++ front-matter so a `+++ … title = "x" … +++` block doesn't
    # accidentally match the admonition regex on something like a stray !!!.
    if i <= n && strip(lines[i]) == "+++"
        i += 1
        while i <= n && strip(lines[i]) != "+++"
            i += 1
        end
        i <= n && (i += 1)
    end

    while i <= n
        h = match(header, lines[i])
        if h === nothing
            i += 1
            continue
        end
        category = h.captures[1]
        i += 1
        body_lines = String[]
        while i <= n && match(header, lines[i]) === nothing
            ln = lines[i]
            push!(body_lines, startswith(ln, "    ") ? chop(ln; head = 4, tail = 0) : ln)
            i += 1
        end
        if category == "user"
            body = strip(join(body_lines, '\n'))
            return isempty(body) ? nothing : String(body)
        end
    end
    return nothing
end

# ── History block writers ────────────────────────────────────────────────────
# One `history_block(io, msg)` method per persisted message type — the single
# source of truth for chat.md's admonition shapes. Both the live append path
# (`append_user`/`finalize_agent`/…) and the whole-file `rewrite_history`
# (reconcile splice path) go through these, so the on-disk shape can't drift
# between the two. Each writer mirrors its append counterpart's gating (empty
# agent text / empty thought / non-terminal tool → no block).

function history_block(io::IO, msg::UserMsg)
    println(io, "!!! user \"$(now(UTC))\"")
    for line in split(msg.text, '\n')
        println(io, "    ", line)
    end
    println(io)
end

function history_block(io::IO, msg::AgentMsg)
    isempty(msg.text) && return
    println(io, "!!! assistant \"$(now(UTC))\"")
    for line in split(msg.text, '\n')
        println(io, "    ", line)
    end
    println(io)
end

function history_block(io::IO, msg::ThoughtMsg)
    isempty(strip(msg.text)) && return
    println(io, "!!! thought \"$(msg.id)\"")
    for line in split(msg.text, '\n')
        println(io, "    ", line)
    end
    println(io)
end

function history_block(io::IO, msg::ToolMsg)
    # Only terminal tools are history (mirrors the `status in ("completed",
    # "failed")` gate at the live append_tool call sites): a live/pending tool
    # gets its block when it finalizes.
    tool_status(msg) in ("completed", "failed") || return
    # 4th field: the resolved filter key (`tool_key`) — persisting it makes
    # the typed variants (Bash/Task/MCP…) reload with stable per-tool
    # filter identities even though reload lands as `GenericToolMsg`.
    meta = "$(tool_kind(msg)) · $(tool_status(msg)) · $(tool_id(msg)) · $(tool_key(msg))"
    println(io, "!!! tool \"$meta\"")
    println(io, "    `$(tool_title(msg))`")
    # Brief summary on the collapsed header; full ACP body lives in
    # the chat-storage `tools/<id>.json` (see update_tool_file!).
    if !isempty(tool_summary(msg))
        println(io, "")
        println(io, "    $(tool_summary(msg))")
    end
    println(io)
end

function history_block(io::IO, msg::TodoListMsg)
    println(io, "!!! plan")
    # Write as plain lines (not markdown list) so admonition_text can round-trip them
    for e in msg.entries
        mark = e.status == "completed" ? "x" : " "
        println(io, "    [$mark] $(e.content)")
    end
    println(io)
end

function history_block(io::IO, msg::SummaryMsg)
    isempty(strip(msg.text)) && return
    println(io, "!!! summary \"$(now(UTC))\"")
    for line in split(msg.text, '\n')
        println(io, "    ", line)
    end
    println(io)
end

# Append messages
# All `append_*` writers take the per-file lock (T13) so an append can't
# interleave with `update_session_id!`'s read-modify-write (which would drop the
# append) and concurrent appenders from different tasks stay whole.
append_block(session::ChatSession, msg::ChatMsg) =
    lock(chat_file_lock(session)) do
        open(io -> history_block(io, msg), session.path, "a")
    end

append_user(session::ChatSession, msg::UserMsg) = append_block(session, msg)

function finalize_agent(session::ChatSession, msg::AgentMsg)
    isempty(msg.text) && return
    append_block(session, msg)
end

# Appended on stream-finalize (a tool call / next message arrives after
# thought chunks). Persisted so a chat reload or agent restart keeps the
# thinking trail visible. Empty thoughts (zero-byte chunks observed during
# replay edge cases) are skipped to keep chat.md clean.
function append_thought(session::ChatSession, msg::ThoughtMsg)
    isempty(strip(msg.text)) && return
    append_block(session, msg)
end

append_tool(session::ChatSession, msg::ToolMsg) = append_block(session, msg)

append_plan(session::ChatSession, msg::TodoListMsg) = append_block(session, msg)

# `/compact` summary boundary, persisted under its own block so reload doesn't
# have to re-classify by matching the verbatim Claude Code prefix every time.
function append_summary(session::ChatSession, msg::SummaryMsg)
    isempty(strip(msg.text)) && return
    append_block(session, msg)
end

"""
    rewrite_history(session, msgs)

Atomically rewrite the WHOLE chat.md from `msgs` (front-matter header + one
`history_block` per message, in order). Used by `reconcile_replay!` when a
resumed session's replay has to be SPLICED into the middle of the stored
history (adopted messages land before the user's still-unsent bubbles) — an
append can't express that, and chat.md is canonical, so the file must be
rebuilt in store order. Runs under the per-file lock so live appends and the
`update_session_id!` header RMW can't interleave with the rebuild.
"""
function rewrite_history(session::ChatSession, msgs::AbstractVector)
    lock(chat_file_lock(session)) do
        atomic_write_text(session.path) do io
            print_front_matter(io, session)
            println(io)
            for m in msgs
                history_block(io, m)
            end
        end
    end
end

"""
    backup_history!(session) -> Union{String,Nothing}

Preserve the current chat.md as `chat.md.bak` (overwriting an older backup).
Called by the fully-diverged reconcile path right before the visible history is
rebuilt from the live session's replay — the jsonl is the source of truth at
that point, but the old canonical transcript must survive on disk. Returns the
backup path, or `nothing` when there is no chat.md yet.
"""
function backup_history!(session::ChatSession)
    lock(chat_file_lock(session)) do
        isfile(session.path) || return nothing
        bak = session.path * ".bak"
        cp(session.path, bak; force = true)
        return bak
    end
end

# Load history from file.
#
# chat.md is hand-written by the `append_*` / `finalize_*` writers above in a
# fixed shape: a `+++` TOML front-matter block, then a sequence of admonition
# blocks — a `!!! <category> "<title>"` header followed by the body with every
# line indented 4 spaces. We parse it BY HAND rather than via CommonMark:
# CommonMark would re-parse each body as markdown, and reconstructing text
# from that AST is lossy (paragraph breaks, headings and tables all collapse —
# only inline `code` survives). The body is literally the message text + a
# 4-space indent, so the faithful inverse is just to strip the indent.
function load_history(session::ChatSession)::Vector{ChatMsg}
    isfile(session.path) || return ChatMsg[]
    lines = split(read(session.path, String), '\n')
    n = length(lines)

    i = 1
    # Skip the +++ front-matter block (parsed separately by parse_session_meta).
    if i <= n && strip(lines[i]) == "+++"
        i += 1
        while i <= n && strip(lines[i]) != "+++"
            i += 1
        end
        i <= n && (i += 1)   # step past the closing +++
    end

    msgs = ChatMsg[]
    # Admonition header: `!!! <category>` with an optional `"<title>"`.
    header = r"^!!! (\w+)(?:\s+\"(.*)\")?\s*$"
    while i <= n
        h = match(header, lines[i])
        if h === nothing
            i += 1
            continue
        end
        category = h.captures[1]
        title    = h.captures[2] === nothing ? "" : String(h.captures[2])
        i += 1
        # Body runs until the next admonition header (or EOF). Indented lines
        # are dedented by 4; blank lines are kept verbatim so paragraph breaks
        # survive. `strip` at the end drops the trailing separator blank.
        body_lines = String[]
        while i <= n && match(header, lines[i]) === nothing
            ln = lines[i]
            push!(body_lines, startswith(ln, "    ") ? chop(ln; head = 4, tail = 0) : ln)
            i += 1
        end
        body = strip(join(body_lines, '\n'))

        if category == "user"
            push!(msgs, UserMsg(String(body)))
        elseif category == "assistant"
            push!(msgs, AgentMsg(string(length(msgs)), String(body)))
        elseif category == "tool"
            # title encodes "kind · status · id · name" — the 4th field (the
            # tool's filter key) was added later; legacy 3-field chats parse
            # with an empty name and fall back to filtering by kind.
            parts = split(title, " · "; limit = 4)
            kind, status, id, name =
                length(parts) == 4 ? parts :
                length(parts) == 3 ? (parts..., "") : ("other", "completed", "", "")
            # body is `` `<tool title>` `` then an optional summary line.
            title_line = match(r"`([^`]*)`", body)
            tool_title = title_line !== nothing ? String(title_line.captures[1]) : ""
            summary = ""
            if title_line !== nothing
                tail = strip(body[nextind(body, title_line.offset + ncodeunits(title_line.match) - 1):end])
                summary = String(tail)
            end
            # Reload always lands as the generic variant — by the time chat.md
            # was written, every tool had reached terminal status, so the
            # subtype-specific fields (background flag, MCP server, …) no
            # longer drive any live UX. New tool calls in the resumed session
            # come through the typed dispatcher again.
            push!(msgs, GenericToolMsg(Message(string(id), string(kind),
                                       string(name), tool_title, string(status),
                                       summary, time(), time(), nothing)))
        elseif category == "plan"
            entries = PlanEntry[]
            for line in split(body, '\n')
                m = match(r"\[( |x)\] (.+)", line)
                m === nothing && continue
                status = m.captures[1] == "x" ? "completed" : "pending"
                push!(entries, PlanEntry(String(m.captures[2]), "", status))
            end
            isempty(entries) || push!(msgs, TodoListMsg(string(uuid4()), entries,
                                                        time(), time(), nothing))
        elseif category == "thought"
            # `!!! thought "<id>"` — reload the (non-empty) reasoning so a
            # reopened chat keeps the trail. `title` is the original thought id
            # so the lazy `thought.render` round-trip still finds it.
            isempty(strip(body)) || push!(msgs, ThoughtMsg(String(title), String(body)))
        elseif category == "summary"
            # `/compact` boundary — centered separator, NOT a user bubble.
            isempty(strip(body)) || push!(msgs, SummaryMsg(String(body)))
        end
    end
    return msgs
end
