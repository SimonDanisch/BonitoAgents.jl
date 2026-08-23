# bt_dev_* — the tools a "Debug BonitoAgents" chat gets, and no other chat does.
#
# They ask the RUNNING BonitoAgents server about itself over the control channel
# this MCP process already holds (`call_server`): live workers and chats, memory
# and leak counters, the server's own log ring, and a small set of orchestration
# ops. The server implements every op in `dev_api.jl`; this file is the schema +
# the presentation.
#
# Gating: the tools are registered unconditionally (the registry is baked at
# precompile time — see `Tool.available`) and made VISIBLE only when the server
# injected `BONITOAGENTS_DEV_TOOLS=1` into this process's environment, which it
# does for the debug project alone. A normal chat's agent never sees them in
# `tools/list`, and can't call them by guessing the name either.
#
# Why the agent needs them at all: the debug chat's cwd is the BonitoAgents
# CHECKOUT, so the agent can already read and edit the source and run git. What
# it cannot do from the filesystem is see what the live server is doing — which
# chats are bound, what the eval bridges are holding, whether memory grew over
# the last ten minutes. That's what these add.

const DEV_TOOLS_ENV = "BONITOAGENTS_DEV_TOOLS"

"""
    dev_tools_enabled() -> Bool

Whether this MCP process is serving a debug chat. Read from the environment on
every call (not memoised into a const): the value is a property of the process
we were spawned into, and a `const` would be frozen at precompile time.
"""
dev_tools_enabled() = get(ENV, DEV_TOOLS_ENV, "") == "1"

# Every dev tool answers with one JSON blob. JSON rather than a prose summary
# because the agent is going to compare two readings of it (before/after a GC, or
# ten minutes apart) and prose makes that guesswork.
function dev_result(value)
    txt = try
        JSON.json(value, 2)
    catch e
        # A value the server built that JSON can't render is a bug on that side;
        # say so rather than returning an empty tool result.
        "could not encode the server's reply as JSON: $(sprint(showerror, e))\n$(repr(value))"
    end
    return Dict{String,Any}("content" => [Dict("type" => "text", "text" => txt)],
                            "isError" => false)
end

dev_error(msg::AbstractString) =
    Dict{String,Any}("content" => [Dict("type" => "text", "text" => "error: $msg")],
                     "isError" => true)

# One place where a failed server call becomes a tool error. The message is the
# server's verbatim — "worker 'x' is not connected" is exactly what the agent
# needs, and wrapping it in our own wording only loses information.
function dev_call(op::AbstractString; timeout::Real = 30.0, kw...)
    try
        return dev_result(call_server(op; timeout, kw...))
    catch e
        e isa InterruptException && rethrow()
        return dev_error(sprint(showerror, e))
    end
end

const DEV_INSPECT_SECTIONS = ("overview", "workers", "worker", "projects", "chats",
                              "evals", "settings")

const DEV_INSPECT_DESCRIPTION = """
Inspect the LIVE state of the BonitoAgents server this chat is running inside.

Sections:
  • overview  — server uptime, base url, counts of workers / projects / open
                chats / bound sessions, and which chats are currently bound.
  • workers   — every registered worker AS THE SERVER SEES IT: id, name, online,
                projects_root, the last-scan age, and whether its control
                websocket is connected.
  • worker    — what a worker says about ITSELF, asked live: pid, uptime, memory,
                the agent binary it resolves, and each live agent session with
                whether its process is still running and its ACP socket is up.
                Pass `worker_id` for one, omit it for all. When this disagrees
                with `workers`, the disagreement is the bug.
  • projects  — every project: id, title, worker, worker_path, server mirror
                path, backup status, resume session id, dismissed flag.
  • chats     — every live ChatModel: project, message count, busy state, whether
                the ACP session is alive, last error, taskbar items.
  • evals     — the eval bridges (one per project with a live worker eval): the
                connection state, parked-frame bytes, open page roots and pending
                control requests. This is where "the plot never rendered" lives.
  • settings  — server-wide session-config defaults and the last reported config
                options.

Pass `project_id` to narrow `projects` / `chats` / `evals` to one chat.

This reads the real objects in the running process — it is not a file on disk and
not a snapshot. Two calls a few minutes apart are the intended way to see drift.
"""

register!("bt_dev_inspect", DEV_INSPECT_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "section" => Dict("type" => "string", "enum" => collect(DEV_INSPECT_SECTIONS),
                              "description" => "Which part of the server to report."),
            "project_id" => Dict("type" => "string",
                              "description" => "Optional: restrict the report to one chat/project."),
            "worker_id" => Dict("type" => "string",
                              "description" => "Optional: for section=worker, which worker to ask."),
        ),
        "required" => ["section"],
    ),
    function (args::AbstractDict)
        section = String(get(args, "section", "overview"))
        section in DEV_INSPECT_SECTIONS ||
            return dev_error("unknown section '$section'; expected one of " *
                             join(DEV_INSPECT_SECTIONS, ", "))
        return dev_call("inspect"; section = section,
                        project_id = String(get(args, "project_id", "")),
                        worker_id  = String(get(args, "worker_id", "")))
    end;
    available = dev_tools_enabled)

const DEV_LOGS_DESCRIPTION = """
Read the BonitoAgents server's own log ring — the `@info` / `@warn` / `@error`
records the running process emitted, newest last.

The ring is in memory and bounded, so it holds the recent past, not history.
Filter it rather than dumping it:
  • `limit`    — how many records to return (default 100, newest kept).
  • `level`    — minimum level: "debug", "info", "warn", "error".
  • `contains` — case-insensitive substring the message or its key/values must
                 contain (e.g. a project id, "worker", "eval bridge").

Each record carries its timestamp, level, module, source location and the
key/value pairs the log site attached — so a warning about a specific chat can be
traced back to the exact line that emitted it.
"""

register!("bt_dev_logs", DEV_LOGS_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "limit"    => Dict("type" => "integer", "description" => "Max records (default 100)."),
            "level"    => Dict("type" => "string", "enum" => ["debug", "info", "warn", "error"],
                               "description" => "Minimum level to include."),
            "contains" => Dict("type" => "string",
                               "description" => "Case-insensitive substring filter."),
        ),
    ),
    function (args::AbstractDict)
        limit = get(args, "limit", 100)
        return dev_call("logs";
                        limit = limit isa Integer ? Int(limit) : tryparse(Int, String(limit)),
                        level = String(get(args, "level", "info")),
                        contains = String(get(args, "contains", "")))
    end;
    available = dev_tools_enabled)

const DEV_MEMORY_DESCRIPTION = """
Memory and leak counters for the running BonitoAgents server.

Always reported: RSS, Julia's GC live bytes, total allocated since start, GC
counts, thread/task counts, and the sizes of every registry that has ever grown
without bound in this codebase — chat models and their message stores, pending
RPCs, eval bridges and their parked-frame bytes, the mirror-stamp table, the
bound-session LRU, and per-chat websocket/session counts.

Options:
  • `gc = true`   — run a full GC first and report live bytes BEFORE and AFTER.
                    That difference is what separates "garbage we haven't
                    collected" from "something is still referenced".
  • `deep = true` — also walk `Base.summarysize` over the big structures for a
                    real byte count per registry. Accurate and SLOW: seconds on a
                    busy server, and it holds each CHAT's own lock while measuring
                    that chat's message store, so that chat stops rendering for
                    the duration (other chats and the server keep going). Use it
                    once you know which registry to look at, not as a first step.

The way to use this for a leak: take a reading, exercise the thing you suspect
(open and close a chat 20 times, run an eval that plots), take another reading
with `gc = true`, and compare the counters that grew.
"""

register!("bt_dev_memory", DEV_MEMORY_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "gc"   => Dict("type" => "boolean",
                           "description" => "Run a full GC and report live bytes before/after."),
            "deep" => Dict("type" => "boolean",
                           "description" => "Also compute Base.summarysize per registry (SLOW)."),
        ),
    ),
    # Deep walks and GCs take real time on a loaded server, so this one gets a
    # longer window than the default before it gives up.
    args -> dev_call("memory"; timeout = 120.0,
                     gc = get(args, "gc", false) === true,
                     deep = get(args, "deep", false) === true);
    available = dev_tools_enabled)

const DEV_CONTROL_DESCRIPTION = """
Drive the BonitoAgents server: the operations a user would otherwise perform by
clicking. Use this to reproduce a bug end-to-end, or to set up the state a fix
needs to be tested against.

Operations (`op`):
  • `open_chat`     — bring up (or focus) a project's chat session.
                      Args: `project_id`.
  • `send_message`  — send a user message into a chat and return immediately;
                      the reply lands in that chat, not here.
                      Args: `project_id`, `text`.
  • `restart_chat`  — stop and respawn a chat's agent process. Args: `project_id`.
  • `close_chat`    — drop a chat from the open list (the thread is kept on disk).
                      Args: `project_id`.
  • `rescan_worker` — re-scan a worker for agent sessions. Args: `worker_id`.
  • `move_project`  — copy a project's files from the worker it lives on to
                      another worker (the cross-worker sync the UI's ⇄ button
                      runs), then point the project at the destination.
                      Args: `project_id`, `worker_id` (the destination).
  • `set_title`     — rename a chat. Args: `project_id`, `title`.

These have real effects on the user's live session — a `send_message` starts an
agent turn that costs tokens, `move_project` writes files on another machine.
Say what you are about to do before doing it.
"""

const DEV_CONTROL_OPS = ("open_chat", "send_message", "restart_chat", "close_chat",
                         "rescan_worker", "move_project", "set_title")

register!("bt_dev_control", DEV_CONTROL_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "op"         => Dict("type" => "string", "enum" => collect(DEV_CONTROL_OPS),
                                 "description" => "The operation to perform."),
            "project_id" => Dict("type" => "string", "description" => "Target chat/project id."),
            "worker_id"  => Dict("type" => "string", "description" => "Target worker id."),
            "text"       => Dict("type" => "string", "description" => "Message body for send_message."),
            "title"      => Dict("type" => "string", "description" => "New title for set_title."),
        ),
        "required" => ["op"],
    ),
    function (args::AbstractDict)
        op = String(get(args, "op", ""))
        op in DEV_CONTROL_OPS ||
            return dev_error("unknown op '$op'; expected one of " * join(DEV_CONTROL_OPS, ", "))
        # A cross-worker copy moves a whole project tree over the network; the
        # default 30s would time out on anything real.
        timeout = op == "move_project" ? 900.0 : 60.0
        return dev_call("control"; timeout = timeout, op = op,
                        project_id = String(get(args, "project_id", "")),
                        worker_id  = String(get(args, "worker_id", "")),
                        text       = String(get(args, "text", "")),
                        title      = String(get(args, "title", "")))
    end;
    available = dev_tools_enabled)
