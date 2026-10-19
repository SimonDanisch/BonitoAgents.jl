# bt_dev_* — the tools a "Debug BonitoAgents" chat gets, and no other chat does.
#
# They ask the RUNNING BonitoAgents server about itself over the control channel
# this MCP process already holds (`call_server`): live workers and chats, memory
# and leak counters, the server's own logs, and a small set of orchestration
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


# One place where a failed server call becomes a tool error. The message is the
# server's verbatim — "worker 'x' is not connected" is exactly what the agent
# needs, and wrapping it in our own wording only loses information.
function dev_call(op::AbstractString; timeout::Real = 30.0, kw...)
    try
        return dev_result(call_server(op; timeout, kw...))
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror, e))
    end
end

const DEV_INSPECT_SECTIONS = ("overview", "workers", "worker", "projects", "chats",
                              "evals", "settings", "tabs")

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
  • tabs      — every browser tab the server serves, and the ones that closed
                lately: user, client, what it shows, `connected` (its socket is
                live), Bonito's `status` (`SOFT_CLOSED`: socket gone but still
                served for the cleanup time, queueing everything it is sent;
                `OPEN` or `DISPLAYED` otherwise: a connected page can stay
                `DISPLAYED`), seconds since the socket dropped, queued
                messages, subsessions, and whether the page last said it was
                hidden. The `tab` is the 8 characters the log's "tab opened"
                lines print.

Pass `project_id` to narrow `projects` / `chats` / `evals` to one chat, `tab` to
narrow `tabs` to one tab.

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
            "tab" => Dict("type" => "string",
                              "description" => "Optional: for section=tabs, a tab id or its start."),
        ),
        "required" => ["section"],
    ),
    function (args::AbstractDict)
        section = String(get(args, "section", "overview"))
        section in DEV_INSPECT_SECTIONS ||
            return tool_error("unknown section '$section'; expected one of " *
                             join(DEV_INSPECT_SECTIONS, ", "))
        return dev_call("inspect"; section = section,
                        project_id = String(get(args, "project_id", "")),
                        worker_id  = String(get(args, "worker_id", "")),
                        tab        = String(get(args, "tab", "")))
    end;
    available = dev_tools_enabled)

const DEV_LOGS_DESCRIPTION = """
Read logs from ANY machine in the fleet — the server's in-memory ring, or the log
FILE that the server and every worker write.

`source` picks which, and it is the important argument:
  • omitted / "ring" — the SERVER's own `@info`/`@warn`/`@error` ring. In memory,
    bounded, dies with the process.
  • "server"         — the server's log file.
  • "authelia"       — the login's log (Authelia, on the server's machine): why
    a login, a second factor or a passkey was refused. Servers with a login only.
  • a worker's name or id ("MacBook", "Bosgame", …) — that worker's log file,
    read on that machine.
  • "all"            — the server, its login and every connected worker, in one reply.

Reach for the FILE, not the ring, when the ring cannot have the answer — and it
often cannot. The file is a redirect of the process's stdout and stderr, so it
holds three things no logger ever sees:
  • "UNHANDLED TASK ERROR" — `errormonitor` prints it straight to stderr;
  • the runtime's fatal-signal thread dump, written from C on SIGTERM/SIGSEGV;
  • anything from BEFORE the last restart, since the ring starts empty at boot —
    which is exactly the window you want when a process was restarted for hanging.

You are running on ONE worker, and nothing but the server runs on the server
host. Every other machine's log is reachable only through this tool, so a
cross-machine question ("the server stopped answering — what did the other
workers see?") is one call with source="all".

Filters, applied to whichever source you picked:
  • `limit`    — records/lines (ring default 100, file default 200, cap 2000).
  • `level`    — ring only: minimum "debug" / "info" / "warn" / "error".
  • `contains` — substring match, case-insensitive.
  • `since` / `until` — file only: "2026-09-11 14:40" or "2026-09-11T14:40",
    and spanning a restart is fine. They match our own timestamped records;
    untimestamped lines (stack traces, a signal dump) are kept with the record
    above them, so a trace never gets sliced off the line that raised it. If a
    log predates the timestamping logger the reply says so rather than coming
    back empty.

A machine that has no log file yet answers `ok: false` with the reason rather
than failing the call, so a fan-out over the fleet still returns everyone else.
"""

register!("bt_dev_logs", DEV_LOGS_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "source"   => Dict("type" => "string",
                               "description" => "\"ring\" (default, the server's in-memory log), " *
                                                "\"server\" (the server's log file), \"authelia\" " *
                                                "(the login's), a worker name/id, or \"all\" for every machine."),
            "limit"    => Dict("type" => "integer",
                               "description" => "Max records/lines (ring 100, file 200; cap 2000)."),
            "level"    => Dict("type" => "string", "enum" => ["debug", "info", "warn", "error"],
                               "description" => "Ring only: minimum level to include."),
            "contains" => Dict("type" => "string",
                               "description" => "Case-insensitive substring filter."),
            "since"    => Dict("type" => "string",
                               "description" => "Log file only: e.g. \"2026-09-11 14:40\"."),
            "until"    => Dict("type" => "string",
                               "description" => "Log file only: upper bound, same format as since."),
        ),
    ),
    function (args::AbstractDict)
        limit = get(args, "limit", nothing)
        # Defaulted on the SERVER, not here: the sensible default differs per
        # source (ring 100, file 200) and the server is what knows which.
        kw = Dict{Symbol,Any}(
            :source   => String(get(args, "source", "")),
            :level    => String(get(args, "level", "info")),
            :contains => String(get(args, "contains", "")),
            :since    => String(get(args, "since", "")),
            :until    => String(get(args, "until", "")))
        limit === nothing ||
            (kw[:limit] = limit isa Integer ? Int(limit) : tryparse(Int, String(limit)))
        # A fan-out shells out on every machine in the fleet; one default-timeout
        # worth of patience is not enough for six of them.
        return dev_call("logs"; timeout = 120.0, kw...)
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
  • `continue_project` — "Continue on <worker>": a NEW chat on another worker
                      with the project's files and the agent's memory; the
                      original chat is left as it is. Returns the new chat's id.
                      Args: `project_id`, `worker_id` (the destination).
  • `set_title`     — rename a chat. Args: `project_id`, `title`.

These have real effects on the user's live session — a `send_message` starts an
agent turn that costs tokens, `continue_project` writes files on another machine.
Say what you are about to do before doing it.
"""

const DEV_CONTROL_OPS = ("open_chat", "send_message", "restart_chat", "close_chat",
                         "rescan_worker", "continue_project", "set_title")

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
            return tool_error("unknown op '$op'; expected one of " * join(DEV_CONTROL_OPS, ", "))
        # A cross-worker copy moves a whole project tree over the network; the
        # default 30s would time out on anything real.
        timeout = op == "continue_project" ? 900.0 : 60.0
        return dev_call("control"; timeout = timeout, op = op,
                        project_id = String(get(args, "project_id", "")),
                        worker_id  = String(get(args, "worker_id", "")),
                        text       = String(get(args, "text", "")),
                        title      = String(get(args, "title", "")))
    end;
    available = dev_tools_enabled)

const DEV_TIMINGS_DESCRIPTION = """
How long the server's work took, kept for the last 500 of each kind:

  • page          — building a page's HTML (what a browser waits for before it
                    sees anything), with `phases`: the timed parts (handler,
                    sidebar, dashboard, settings, overview_cards, chat_icons,
                    apps, accounts, shares, workspace) and `render` (Bonito
                    rendering the components to HTML after the handler
                    returned), slowest first, down to 1 ms. They nest, so they
                    don't add up.
  • browser_load  — what pages reported about their own load: html, scripts,
                    connected and chat_ms in ms, `why` = ready | gave_up.
  • chat_command  — each command a tab sent a chat (`type`), which the tab
                    waits on.
  • worker_rpc    — each request to a worker (`op` names it and the worker).
  • notify        — a change fanned out to every tab (`signal`: chats, turn,
                    projects, workers, discovered): its cost grows with the open
                    tabs, closed-but-kept ones included.
  • scan          — scanning a worker for agent sessions.
  • ws_upgrade    — a page's live connection (websocket) reaching the login
                    gate behind a tunnel: `at` is when it arrived, `tab` whose
                    it is, `seconds` the login check, `status` 101 when let
                    through. Against the page's `tab opened` and its console's
                    "connecting", it says whether a slow connect lost its
                    seconds before the server or in it.

Each kind answers with a `summary` (count, p50, p95, max, total), its 5 `slowest`
and its `recent` entries (newest first). `kind` picks one, `min_seconds` keeps
the recent list to the slow ones, `limit` caps it (default 20). Times are the
server's local time, like its log.
"""

register!("bt_dev_timings", DEV_TIMINGS_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "kind"        => Dict("type" => "string",
                                  "description" => "One kind: page, browser_load, chat_command, worker_rpc, notify, scan, ws_upgrade. Omit for all."),
            "min_seconds" => Dict("type" => "number",
                                  "description" => "Only list recent entries at least this slow."),
            "limit"       => Dict("type" => "integer",
                                  "description" => "Max recent entries per kind (default 20)."),
        ),
    ),
    function (args::AbstractDict)
        kw = Dict{Symbol,Any}(:kind => String(get(args, "kind", "")))
        haskey(args, "min_seconds") && (kw[:min_seconds] = Float64(args["min_seconds"]))
        haskey(args, "limit") && (kw[:limit] = Int(args["limit"]))
        return dev_call("timings"; kw...)
    end;
    available = dev_tools_enabled)

const DEV_CONSOLE_DESCRIPTION = """
The JavaScript console of a browser tab: what the page logged, warned and threw
(`console.*`, uncaught errors, unhandled promise rejections), as the page kept it.

  • without `tab` — the tabs, open and recently closed, with their status and how
    many entries they sent the server.
  • with `tab`    — that tab's console (`tab` = the id or its start, as
    `bt_dev_inspect section=tabs` and the log's "tab opened" lines show it).
    A connected tab is asked live (`source: "live"`: its last 1000 entries). A
    tab that is gone, asleep (a phone in the background) or asked with
    `live = false` answers with what it beaconed whenever it was hidden, shown
    or left (`source: "beacons"`).

Filters: `level` (minimum: debug, log, info, warn, error), `contains`
(case-insensitive), `limit` (the newest N, default 200). A page loaded before the
console capture existed has none; reloading it starts one.
"""

register!("bt_dev_console", DEV_CONSOLE_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "tab"      => Dict("type" => "string", "description" => "A tab id or its start. Omit to list the tabs."),
            "level"    => Dict("type" => "string", "enum" => ["debug", "log", "info", "warn", "error"],
                               "description" => "Minimum level."),
            "contains" => Dict("type" => "string", "description" => "Case-insensitive substring filter."),
            "limit"    => Dict("type" => "integer", "description" => "The newest N entries (default 200)."),
            "live"     => Dict("type" => "boolean",
                               "description" => "Ask a connected tab (default true); false reads what it beaconed."),
        ),
    ),
    function (args::AbstractDict)
        kw = Dict{Symbol,Any}(:tab => String(get(args, "tab", "")),
                              :level => String(get(args, "level", "debug")),
                              :contains => String(get(args, "contains", "")),
                              :live => get(args, "live", true) !== false)
        haskey(args, "limit") && (kw[:limit] = Int(args["limit"]))
        return dev_call("console"; kw...)
    end;
    available = dev_tools_enabled)
