# ── Export a chat as Markdown (the ⋯ menu's "Export as Markdown") ─────────────
# The whole chat as one self-contained .md file, served by `/export/<pid>`
# (server.jl): messages, reasoning, todo lists and every tool call with its full
# body from tools/<id>.json. Unlike `chat.md`, the compact reload format with tool
# bodies summarized, it is written to be read and shared. Each tool type is
# written the way its card shows it: an edit as its diff, rebuilt from the call's
# input when the agent sent no diff block, an eval as code plus output.
#
# The file is also a BonitoBook notebook. Each Julia eval of the chat becomes a
# BonitoBook cell (`BonitoBook.write_code_fence(io, ::Cell)`) and everything else
# is markdown between the cells, so `BonitoBook.Book(file)` opens the chat with
# the agent's Julia code as cells to run again. Opening a book runs none of them.
# Every fence goes through BonitoBook's fence writer, which grows the fence past
# any run of backticks in the content.
#
# Files and images are referenced by path, never embedded. A path names the file
# as it is NOW, which may differ from that point of the chat, so each one carries
# ⚠️ and the header explains that once.

# The export being written: the stream, the chat's folder (tool bodies and
# arguments are stored there) and the last BonitoBook cell id handed out.
mutable struct ChatExport
    io::IOBuffer
    chat_dir::String
    cell_id::Int
end
ChatExport(chat_dir::AbstractString) = ChatExport(IOBuffer(), String(chat_dir), 0)

# Inline code that survives backticks in `s`: a backtick run longer than any in it.
function inline_code(s::AbstractString)
    ticks = "`"
    while occursin(ticks, s)
        ticks *= "`"
    end
    pad = startswith(s, '`') || endswith(s, '`') ? " " : ""
    return string(ticks, pad, s, pad, ticks)
end

file_ref(path::AbstractString) = string(inline_code(path), " ⚠️")

# One paragraph, then the blank line that ends it.
paragraph(ex::ChatExport, text::AbstractString) = println(ex.io, rstrip(text), "\n")

# A fenced block through BonitoBook's writer. Trailing newlines would show as
# blank lines inside the fence.
function fence(ex::ChatExport, lang::AbstractString, text::AbstractString)
    BonitoBook.write_code_fence(ex.io, lang, rstrip(text, '\n'))
    println(ex.io)
end

# ── Messages ──────────────────────────────────────────────────────────────────

function export_md!(ex::ChatExport, m::UserMsg)
    # `auto`: a message the app wrote (the Yolo nudge), not the user.
    paragraph(ex, m.auto ? "## ⚙️ Automatic message" : "## 🧑 User")
    paragraph(ex, m.text)
end

export_md!(ex::ChatExport, m::AgentMsg) = (paragraph(ex, "## 🤖 Assistant"); paragraph(ex, m.text))

export_md!(ex::ChatExport, m::SummaryMsg) =
    (paragraph(ex, "## 📝 Summary (/compact)"); paragraph(ex, m.text))

function export_md!(ex::ChatExport, m::ThoughtMsg)
    paragraph(ex, "### 💭 Reasoning")
    for l in split(rstrip(m.text), '\n')
        println(ex.io, isempty(l) ? ">" : "> " * l)
    end
    println(ex.io)
end

function export_md!(ex::ChatExport, m::TodoListMsg)
    paragraph(ex, "### ✅ Todo")
    for e in m.entries
        println(ex.io, "- [", e.status == "completed" ? "x" : " ", "] ", e.content,
                e.status == "in_progress" ? " _(in progress)_" : "")
    end
    println(ex.io)
end

function export_md!(ex::ChatExport, m::ToolMsg)
    restore_input!(ex, m)
    v = export_view(m)
    status = tool_status(v)
    paragraph(ex, string("### 🔧 ", export_tool_name(v), isempty(status) ? "" : " · " * status))
    export_input!(ex, v)
    export_body!(ex, v, tool_content_for_render(v, ex.chat_dir))
end

# A chat reopened from chat.md gets its tool calls back without their arguments.
# They are stored beside it (tools/<id>.json), where `tool_file_path` reads them too.
function restore_input!(ex::ChatExport, m::ToolMsg)
    raw = stored_raw_input(ex.chat_dir, tool_id(m))
    raw === nothing || apply_input!(m, raw)
    return
end

# A reopened chat restores a tool call by its built-in kind only (`load_history`):
# a Bash call or an MCP call such as bt_julia_eval comes back generic, with its
# name (`tool_key`) and arguments. The export writes it as the live chat did,
# from a typed copy; the stored message stays generic (see `load_history` for why).
export_view(m::ToolMsg) = m

function export_view(m::GenericToolMsg)
    if m.message.name == "Bash"
        v = BashToolMsg(copy(m.message))
        apply_input!(v, m.raw_input)
        return v
    end
    r = resolve_mcp_tool(m.message.name)
    r === nothing && return m
    server, tool = r
    v = build_mcp_msg(mcp_msg_type(tool), copy(m.message), server, tool)
    apply_input!(v, m.raw_input)
    return v
end

# The tool as the agent names it, without an MCP tool's `mcp__<server>__` prefix.
export_tool_name(m::ToolMsg) =
    first(pretty_tool_title(isempty(m.message.name) ? tool_kind(m) : m.message.name))
export_tool_name(::JuliaEvalToolMsg) = "bt_julia_eval"
export_tool_name(::JuliaContinueToolMsg) = "bt_julia_continue"

# ── A tool's input ────────────────────────────────────────────────────────────

function export_input!(ex::ChatExport, m::ToolMsg)
    t = tool_title(m)
    isempty(t) && return
    occursin('\n', t) ? fence(ex, "", t) : paragraph(ex, inline_code(t))
end

function export_input!(ex::ChatExport, m::BashToolMsg)
    d = something(m.description, "")
    isempty(d) || paragraph(ex, "_" * d * "_")
    command = isempty(m.command) ? tool_title(m) : m.command
    isempty(command) || fence(ex, "sh", command)
end

function export_input!(ex::ChatExport, m::TaskToolMsg)
    d = isempty(m.description) ? tool_title(m) : m.description
    isempty(d) || paragraph(ex, "_" * d * "_")
end

# An edit's diff names its file (`export_body!`).
export_input!(::ChatExport, ::EditToolMsg) = nothing

export_input!(ex::ChatExport, m::ReadToolMsg) =
    isempty(m.file_path) || paragraph(ex, "File: " * file_ref(m.file_path))

export_input!(ex::ChatExport, m::ShowToolMsg) =
    isempty(m.path) || paragraph(ex, "File: " * file_ref(m.path))

function export_input!(ex::ChatExport, m::SearchToolMsg)
    isempty(m.pattern) || paragraph(ex, "Pattern: " * inline_code(m.pattern))
    isempty(m.path) || paragraph(ex, "Path: " * file_ref(m.path))
end

# The eval's code as a BonitoBook cell, after where it ran: the cell itself runs
# wherever the book is opened.
function export_input!(ex::ChatExport, m::JuliaEvalToolMsg)
    place = isempty(m.env_path) ? "a temporary environment" : "env " * inline_code(m.env_path)
    isempty(m.worker) || (place *= " on worker " * inline_code(m.worker))
    paragraph(ex, "Ran in " * place * (m.background ? ", in the background" : ""))
    isempty(m.code) && return
    ex.cell_id += 1
    BonitoBook.write_code_fence(ex.io, BonitoBook.Cell("julia", String(rstrip(m.code, '\n')), nothing,
                                                       true, false, true, ex.cell_id, Dict{Symbol,Any}()))
    println(ex.io)
end

export_input!(ex::ChatExport, m::JuliaContinueToolMsg) =
    isempty(m.run) || paragraph(ex, "Continues run " * inline_code(m.run))

# ── A tool's body ─────────────────────────────────────────────────────────────

export_body!(ex::ChatExport, ::ToolMsg, content) = export_parts!(ex, content)

export_parts!(ex::ChatExport, content) = foreach(c -> export_content!(ex, c), content)

# Like the card: every diff of the call, or the one its input describes when the
# agent sent none (claude-agent-acp folds the diff into a text result).
function export_body!(ex::ChatExport, m::EditToolMsg, content)
    diffs = [c for c in content if c isa DiffContent]
    if isempty(diffs)
        d = edit_diff_from_input(m)
        if d === nothing
            isempty(m.file_path) || paragraph(ex, "File: " * file_ref(m.file_path))
            return export_parts!(ex, content)
        end
        diffs = [d]
    end
    foreach(d -> export_content!(ex, d), diffs)
end

# The input line already names the shown file.
export_body!(ex::ChatExport, ::ShowToolMsg, content) =
    export_parts!(ex, (c for c in content if !(c isa TextContent && parse_show_path(c.text) !== nothing)))

# An eval's content is [output?, descriptor?] (BonitoMCP's wire contract v3):
# what it printed, then the live value's handle, which carries the value's repr
# for the agent. The value is written after the output like a REPL would; an app
# or plot (an html repr) is named, not dumped as markup. A Bonito-upgrade marker
# is left out.
function export_body!(ex::ChatExport, ::JuliaEvalCall, content)
    for c in content
        if c isa TextContent
            bonito_upgrade_descriptor(c.text) === nothing || continue
            r = result_repr(c.text)
            r === nothing || (export_value!(ex, r); continue)
        end
        export_content!(ex, c)
    end
end

function export_value!(ex::ChatExport, r::NamedTuple)
    if r.mime == "text/html"
        paragraph(ex, "_The result, an app or plot, was shown live in the chat; it is not exported._")
    else
        isempty(strip(r.text)) || fence(ex, "text", r.text)
    end
end

function export_content!(ex::ChatExport, c::TextContent)
    text = strip_ansi_codes(c.text)
    isempty(strip(text)) && return
    path = parse_show_path(text)
    path === nothing || return paragraph(ex, "Shown: " * file_ref(path))
    # A block that is one fenced block already keeps its language (the card
    # shows it as code too, `render_text_block`).
    f = fenced_code(text)
    f === nothing ? fence(ex, "text", text) : fence(ex, f...)
end

function export_content!(ex::ChatExport, d::DiffContent)
    paragraph(ex, "Edited " * file_ref(d.path))
    old, new = code_lines(something(d.old_text, "")), code_lines(d.new_text)
    io = IOBuffer()
    i = j = 0
    for (op, n) in line_diff(old, new), _ in 1:n
        if op == '='
            i += 1; j += 1
            println(io, ' ', old[i])
        elseif op == '-'
            i += 1
            println(io, '-', old[i])
        else
            j += 1
            println(io, '+', new[j])
        end
    end
    fence(ex, "diff", String(take!(io)))
end

export_content!(ex::ChatExport, c::ImageContent) =
    paragraph(ex, "🖼️ _An image ($(c.mime_type)), not embedded._")

function export_content!(ex::ChatExport, c::AgentClientProtocol.ResourceLink)
    p = AgentClientProtocol.resource_link_path(c)
    paragraph(ex, "Linked: " * (p === nothing ? inline_code(c.uri) : file_ref(p)))
end

# A terminal block (`parse_tool_content_item` keeps no content for it).
export_content!(::ChatExport, ::Nothing) = nothing

# ── The document ──────────────────────────────────────────────────────────────

function export_title(model::ChatModel)
    p = isempty(model.project_id) ? nothing : get(model.state.projects[], model.project_id, nothing)
    return p === nothing ? basename(rstrip(model.cwd, '/')) : p.title[]
end

function export_filename(model::ChatModel)
    slug = replace(strip(export_title(model)), r"[^\w .-]+" => "", " " => "-")
    return string(isempty(slug) ? "chat" : slug, "-", Dates.format(now(UTC), "yyyy-mm-dd"), ".md")
end

"""
    export_chat_markdown(model) -> String

The whole chat as one Markdown document that is also a BonitoBook notebook:
its Julia evals are cells (see the notes atop `chat_export.jl`).
"""
function export_chat_markdown(model::ChatModel)::String
    s = shared(model)
    ex = ChatExport(s.chat_dir)
    for m in lock(() -> copy(s.msgs_store), s.lock)
        export_md!(ex, m)
    end
    body = take!(ex.io)
    sess = s.chat_session
    io = IOBuffer()
    println(io, "# ", export_title(s), "\n")
    println(io, "- **Project:** ", inline_code(sess.cwd))
    isempty(sess.session_id) || println(io, "- **Session:** ", inline_code(sess.session_id))
    println(io, "- **Created:** ", Dates.format(sess.created, "yyyy-mm-dd HH:MM"), " UTC")
    println(io, "- **Exported:** ", Dates.format(now(UTC), "yyyy-mm-dd HH:MM"), " UTC\n")
    println(io, "> ⚠️ **Files are linked by path, not captured as snapshots.** Every value ",
        "marked ⚠️ below (shown files, edited or read files, search roots) is a path on ",
        "disk. The file may have changed since that point in the chat, later in the ",
        "conversation or by another process, so read a ⚠️ path as \"the file at this path *now*\".\n")
    ex.cell_id > 0 && println(io, "> 📓 **This file is a BonitoBook notebook.** ",
        "`using BonitoBook; Book(\"<this file>\")` opens the chat with ",
        ex.cell_id == 1 ? "its Julia eval" : "each of its $(ex.cell_id) Julia evals",
        " as a cell you can run again. Opening it runs none of them.\n")
    println(io, "---\n")
    write(io, body)
    return String(take!(io))
end
