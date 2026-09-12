# Path to the BonitoAgents package's assets/ (install.jl, bonitoagents.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoAgents/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# The public repository workers are installed from, and the monorepo packages
# `install.jl` puts into a worker's `@bonito-agents` environment from it (its
# `SPECS`; keep the two in step). The "Debug BonitoAgents" chat develops these
# same packages from a clone of this repo on the worker (`ensure_debug_project!`).
const WORKER_REPO_URL = "https://github.com/SimonDanisch/BonitoAgents.jl"
const WORKER_REPO_PACKAGES = ["RemoteSync", "BonitoWorker", "BonitoMCP", "AgentProviders"]

# The worker installer is a cross-platform Julia script (`curl … | julia -`).
# It Pkg.add's BonitoWorker + BonitoMCP from the public GitHub repo into a
# shared `@bonito-agents` env — no tar bundle, no per-package source trees, runs
# identically on Linux / macOS / Windows. See assets/install.jl.
#
# Around it sit two tiny per-shell bootstraps so the install one-liner mirrors
# the familiar `curl URL | sh` shape on each OS. They only check that `julia`
# is on PATH and then hand off to install.jl — they do NOT install juliaup
# (Julia is a prerequisite the user installs separately).

Base.include_dependency(joinpath(ASSETS_DIR, "install.jl"))
Base.include_dependency(joinpath(ASSETS_DIR, "install.sh"))
Base.include_dependency(joinpath(ASSETS_DIR, "install.ps1"))

const INSTALL_SCRIPT = read(joinpath(ASSETS_DIR, "install.jl"), String)
const INSTALL_SH     = read(joinpath(ASSETS_DIR, "install.sh"),  String)
const INSTALL_PS1    = read(joinpath(ASSETS_DIR, "install.ps1"), String)

"""
    serve(; host, port, public_url, worker_secret, state_dir, working_dir) → Bonito.Server

Start the BonitoAgents dashboard server. Workers dial back to this server, so
only port `port` (default 8038) needs to be open in the server's firewall.

Routes:
  /                       — dashboard (workers + projects)
  /p/<project_id>         — chat UI for one project
  /install                — OS-sniffing bootstrap (`curl … | sh` / `irm … | iex`)
  /install.sh             — bash wrapper (Linux / macOS)
  /install.ps1            — PowerShell wrapper (Windows)
  /install.jl             — cross-platform worker installer (used by the wrappers)
  /worker-ws    (WS)      — control channel each worker holds open after install
  /worker-acp   (WS)      — per-session ACP relay; one connection per project session
  /transfer-ws  (WS)      — librsync directional transfer; dialed on demand by a
                            worker in response to an `open_transfer` command

`worker_secret` is the shared secret used by every worker. `public_url` is the
base URL workers see (and what the install script tells them to dial back).

`state_dir`   overrides where workers.json / projects.json are persisted
              (default: `~/.local/share/bonitoagents-server`).
`working_dir` overrides where canonical project copies live on the server.
              Each project lives at `<working_dir>/<name>` and is mirrored
              onto the worker at `<worker.projects_root>/<name>`.
              (default: `~/bonitoagents-server`)
"""
function serve(; host::String        = "0.0.0.0",
                 port::Int           = 8038,
                 public_url::Union{String,Nothing}   = nothing,
                 worker_secret::String,
                 state_dir::Union{String,Nothing}   = nothing,
                 working_dir::Union{String,Nothing} = nothing,
                 heartbeat_interval::Real = 15.0,
                 heartbeat_deadline::Real = 45.0,
                 log_file::Union{String,Nothing} = nothing)
    # `nothing` OR `""` (env-var roundtrip) → use the platform default. Anything
    # else is taken as an absolute override.
    isvalid(s) = s !== nothing && !isempty(String(s))
    sd = isvalid(state_dir)   ? String(state_dir)   :
         joinpath(homedir(), ".local", "share", "bonitoagents-server")
    wd = isvalid(working_dir) ? String(working_dir) :
         joinpath(homedir(), "bonitoagents-server")

    # Start recording our own log output BEFORE anything else can log, so the
    # debug chat's `bt_dev_logs` sees the whole life of the server rather than
    # "everything after the first browser connected". Idempotent + process-wide
    # (the logger is); a second `serve()` in the same process shares the ring.
    #
    # The FILE comes first and the ring second: the file is a redirect of fd 1
    # and 2, so it also catches what never reaches a logger at all — an
    # `errormonitor` task death, the runtime's fatal-signal thread dump — and it
    # is the only one of the two that survives the restart you do when a server
    # hangs.
    #
    # OPT-IN, and it defaults OFF on purpose. This REDIRECTS fd 1 and 2, so a
    # library that did it by default would silently swallow the output of every
    # caller — a REPL, a script, a test runner (nine unit tests call `serve()`
    # directly, and the first version of this took their stdout with it). The
    # SERVER BINARY asks for it; nothing else does. `""` means "the default path
    # under state_dir".
    if log_file !== nothing
        BonitoWorker.start_file_log!(isempty(log_file) ?
            joinpath(sd, "logs", "server.log") : log_file)
    end
    install_log_ring!()
    SERVER_STARTED[] == 0.0 && (SERVER_STARTED[] = time())

    state = ServerState(; state_dir = sd, working_dir = wd, worker_secret = worker_secret,
                          heartbeat_interval = heartbeat_interval,
                          heartbeat_deadline = heartbeat_deadline)

    # Mark all loaded workers offline; they'll flip online when they re-dial.
    for w in values(state.workers[])
        w.online[] = false
    end

    # Survive long browser disconnects (phone goes into pocket, laptop sleeps,
    # network blip) by keeping SOFT_CLOSED sessions alive for an hour, so the
    # browser can reconnect to the SAME session with all of its Observable
    # state — current view, popup geometry, chat consumer task — intact.
    # The new-tab case still falls back to the localStorage last-route memory
    # wired in the sidebar onload.
    Bonito.set_cleanup_time!(1.0)   # hours

    # Single-page app: sidebar + dashboard/chat swap. No per-project routes.
    srv = Bonito.Server(unified_app(state), host, port; proxy_url = ".")
    state.srv = srv

    # online_url uses the post-start srv.port — handles port=0 → ephemeral
    # AND EADDRINUSE → port+1 retry without us tracking the actual port.
    # An EMPTY public_url counts as unset too (the CLI entry point passes ""
    # when --public-url was omitted; `something("", …)` would have kept the
    # empty string and templated install scripts with a blank SERVER_URL).
    base_url = (public_url === nothing || isempty(public_url)) ?
        Bonito.online_url(srv, "") : public_url
    # The dashboard's install snippet renders the SAME url the install routes
    # are templated with — never a "<your-server>" placeholder.
    state.base_url[] = rstrip(base_url, '/')
    add_install_routes!(srv, base_url, worker_secret)
    add_acp_log_routes!(srv, state)
    add_download_routes!(srv, state)
    add_worker_ws_routes!(srv, state)

    # The background-output poller is no longer a server-wide loop — it's
    # per-ChatModel now, spawned in `start_chat_client!` and torn down
    # when the chat goes away. Closes the "global loop forever walking
    # every chat's msgs_store" mismatch with the taskbar's per-chat
    # mental model. See `start_background_poller!` in chat.jl.

    # Show the SAME canonical url the UI + worker-install snippet use (`base_url`
    # = the configured --public-url, or the detected address) — not the bind-based
    # `online_url(srv)` (0.0.0.0/localhost), which mismatched the dashboard's
    # "add worker" url whenever --public-url was set.
    @info "BonitoAgents dashboard running" url=base_url state=sd
    @info "Worker install — run on each agent machine" *
          "\n    Linux / macOS  : curl -fsSL $base_url/install.sh | sh" *
          "\n    Windows (PS)   : irm $base_url/install.ps1 | iex"
    return state
end

# ── Package entry point ──────────────────────────────────────────────────────
# `julia --project=<monorepo root> -m BonitoAgents [flags]` starts the server and
# blocks. No env vars: defaults are baked in (port 8038, host 0.0.0.0) and the
# worker secret is generated + persisted in the state dir on first run, so
# workers keep authenticating across restarts. Override any default with a flag:
#
#   julia --project=. -m BonitoAgents
#   julia --project=. -m BonitoAgents --port 8080
#   julia --project=. -m BonitoAgents --public-url https://team.example.com --secret <hex>
#
# Flags: --port --host --public-url --secret --state-dir --working-dir
function (@main)(args::Vector{String})
    opts = parse_server_args(args)
    sd_arg = get(opts, "state-dir", "")
    state_dir = isempty(sd_arg) ?
        joinpath(homedir(), ".local", "share", "bonitoagents-server") : sd_arg
    secret = get(opts, "secret", "")
    isempty(secret) && (secret = persisted_worker_secret(state_dir))
    serve(;
        worker_secret = secret,
        host          = get(opts, "host", "0.0.0.0"),
        port          = parse(Int, get(opts, "port", "8038")),
        public_url    = get(opts, "public-url", ""),
        state_dir     = state_dir,
        working_dir   = get(opts, "working-dir", ""),
    )
    wait()
    return 0
end

# Tiny CLI parser: accepts `--key value` and `--key=value`; errors on anything
# else so a typo fails loudly instead of silently using a default.
function parse_server_args(args::Vector{String})
    opts = Dict{String,String}()
    i = 1
    while i <= length(args)
        a = args[i]
        startswith(a, "--") ||
            error("unexpected argument `$a` (use --key value or --key=value)")
        body = a[3:end]
        if occursin('=', body)
            k, v = split(body, '='; limit = 2)
            opts[String(k)] = String(v); i += 1
        else
            i < length(args) || error("missing value for --$body")
            opts[body] = args[i + 1]; i += 2
        end
    end
    return opts
end

# Read the persisted worker secret, generating + storing one (mode 600) on first
# run so workers keep authenticating across restarts with no env vars to manage.
function persisted_worker_secret(state_dir::AbstractString)
    mkpath(state_dir)
    f = joinpath(state_dir, "worker_secret")
    if isfile(f)
        s = strip(read(f, String)); isempty(s) || return String(s)
    end
    s = bytes2hex(rand(UInt8, 32))
    write(f, s); chmod(f, 0o600)
    @info "BonitoAgents: generated a new worker secret" file = f
    return s
end

# HTTP routes
#
# /install        — sniffs `User-Agent` and serves either the bash or PS1
#                   wrapper. PowerShell's Invoke-RestMethod sets a UA that
#                   contains the literal "PowerShell"; curl/wget/everything
#                   else falls through to the bash wrapper.
# /install.sh     — always bash wrapper. Useful when /install's sniff guesses
#                   wrong, or when fetched from a browser to inspect.
# /install.ps1    — always PowerShell wrapper. Same.
# /install.jl     — the cross-platform Julia installer the wrappers fetch.
function add_install_routes!(srv::Bonito.Server, public_url::String, worker_secret::String)
    Bonito.route!(srv, "/install.jl" => function(context)
        script = render_install_script(INSTALL_SCRIPT, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)
    Bonito.route!(srv, "/install.sh" => function(context)
        body = render_install_script(INSTALL_SH, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/x-shellscript; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install.ps1" => function(context)
        body = render_install_script(INSTALL_PS1, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install" => function(context)
        ua   = String(HTTP.header(context.request, "User-Agent", ""))
        is_ps = occursin("PowerShell", ua)
        body = render_install_script(is_ps ? INSTALL_PS1 : INSTALL_SH,
                                     public_url, worker_secret)
        ctype = is_ps ? "text/plain; charset=utf-8" :
                        "text/x-shellscript; charset=utf-8"
        HTTP.Response(200, ["Content-Type" => ctype], body=body)
    end)
end

# ── ACP wire-frame log routes ────────────────────────────────────────────────
#
# /acp-log            — HTML index of projects that have an acp.jsonl
# /acp-log/<pid>      — the raw JSONL (one {"ts","dir","msg"} envelope per
#                       line), append-only, written by `acp_frame_logger`.
#                       Refresh the tab to see new frames.
#
# Served straight from disk (state_dir/chats/<pid>/acp.jsonl) so logs are
# readable even when no live ChatModel exists for the project. Legacy
# project-id-less chats (<cwd>/.bonitoAgents) are deliberately NOT exposed.
function add_acp_log_routes!(srv::Bonito.Server, state::ServerState)
    index_handler = function(context)
        chats_root = joinpath(state.state_dir, "chats")
        ids = isdir(chats_root) ?
            filter(id -> isfile(joinpath(chats_root, id, "acp.jsonl")),
                   sort!(readdir(chats_root))) :
            String[]
        items = map(ids) do id
            p = get(state.projects[], id, nothing)
            label = esc_html(p === nothing ? id : "$(p.name) ($id)")
            "<li><a href=\"/acp-log/$id\">$label</a></li>"
        end
        body = isempty(items) ?
            "<p>No ACP logs yet — open a chat and send a message.</p>" :
            "<ul>" * join(items) * "</ul>"
        html = "<!doctype html><html><head><meta charset=\"utf-8\">" *
               "<title>ACP wire logs</title></head>" *
               "<body><h1>ACP wire logs</h1>$body</body></html>"
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], body=html)
    end
    # Both slash variants — String routes match the URI path exactly, so
    # "/acp-log/" (what a browser autocompletes to) needs its own entry.
    Bonito.route!(srv, "/acp-log"  => index_handler)
    Bonito.route!(srv, "/acp-log/" => index_handler)
    Bonito.route!(srv, ACP_LOG_ROUTE_RE => function(context)
        acp_log_response(state, String(context.match.captures[1]))
    end)
end

# `request.target` includes the query string, hence the `($|\?)` arm; the
# `/?` tolerates a trailing slash after the id. The charset (no `.`, no `/`)
# makes path traversal impossible.
const ACP_LOG_ROUTE_RE = r"^/acp-log/([A-Za-z0-9_-]+)/?(?:$|\?)"

# Plain function (no live HTTP server needed) so tests can call it directly.
function acp_log_response(state::ServerState, project_id::AbstractString)
    # Defense-in-depth: the route regex already constrains the charset, but
    # never join an unvalidated id into a filesystem path.
    occursin(r"^[A-Za-z0-9_-]+$", project_id) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "invalid project id\n")
    path = joinpath(state.state_dir, "chats", String(project_id), "acp.jsonl")
    isfile(path) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "no ACP log for project '$project_id'\n")
    return HTTP.Response(200,
        ["Content-Type"  => "text/plain; charset=utf-8",
         "Cache-Control" => "no-cache"],
        body = read(path, String))
end

# /download/<pid>?path=<worker-abs-path> — stream a worker file back to the
# browser as an attachment. The file tree's ⤓ button navigates here. The file
# is fetched from the worker on demand (RemoteSync over the control WS), so it
# works whether or not the project is synced to the server. The `path` MUST live
# inside the project's worker tree — a normalized-prefix check blocks traversal /
# arbitrary worker reads. The route regex captures only the pid; the path rides
# in the query string (so slashes survive without extra encoding rules).
const DOWNLOAD_ROUTE_RE = r"^/download/([A-Za-z0-9_-]+)"

function add_download_routes!(srv::Bonito.Server, state::ServerState)
    Bonito.route!(srv, r"^/worker-file/([A-Za-z0-9_-]+)(?:$|\?)" => function(context)
        wid = String(context.match.captures[1])
        params = HTTP.queryparams(HTTP.URI(context.request.target))
        worker_file_response(state, context.request, wid,
            String(get(params, "path", "")), String(get(params, "token", "")))
    end)
    Bonito.route!(srv, DOWNLOAD_ROUTE_RE => function(context)
        pid    = String(context.match.captures[1])
        params = HTTP.queryparams(HTTP.URI(context.request.target))
        download_response(state, pid, String(get(params, "path", "")))
    end)
    Bonito.route!(srv, ATTACHMENT_ROUTE_RE => function(context)
        pid    = String(context.match.captures[1])
        params = HTTP.queryparams(HTTP.URI(context.request.target))
        attachment_response(state, pid, String(get(params, "file", "")))
    end)
end

# These URLs depend only on persisted worker identity, path, and server secret.
# Signing limits access to files exposed by the UI, including bt_show files
# outside the project tree. No browser/eval session owns or unregisters them.
worker_file_token(state::ServerState, worker_id::String, path::String) =
    bytes2hex(SHA.hmac_sha256(Vector{UInt8}(codeunits(state.worker_secret)),
        codeunits(JSON.json([worker_id, path]))))

function worker_file_url(state::ServerState, worker_id::String, path::String)
    token = worker_file_token(state, worker_id, path)
    return "/worker-file/$(HTTP.escapeuri(worker_id))?path=$(HTTP.escapeuri(path))&token=$token"
end

# Compatibility for workers predating range reads. Keep a versioned mirror so
# seeking in a video doesn't copy the whole file again for every Range request.
function worker_file_copy_response(state::ServerState, request, worker_id::String,
                                   path::String, info)
    key = worker_file_token(state, worker_id, path)
    dst = joinpath(state.state_dir, "worker-files", key, basename(path))
    dst_lock = lock(state.lock) do
        get!(ReentrantLock, state.show_fetch_inflight, dst)
    end
    return lock(dst_lock) do
        stamp = (size=info.size, mtime=info.mtime)
        previous = lock(state.lock) do
            get(state.show_mirror_stamps, dst, nothing)
        end
        if !isfile(dst) || previous != stamp
            mkpath(dirname(dst))
            fetch_file_from_worker(state, worker_id, path, dst)
            after = stat_worker_path(state, worker_id, path)
            lock(state.lock) do
                delete!(state.show_mirror_stamps, dst)
                (size=after.size, mtime=after.mtime) == stamp &&
                    (state.show_mirror_stamps[dst] = stamp)
            end
        end
        # Mirror mtimes are transfer times. Do not let a browser validate them
        # at whole-second precision and miss two rapid rewrites of the source.
        return Bonito.serve_asset(request, nothing, dst,
                                   string(Bonito.file_mimetype(path)), "no-store")
    end
end

function worker_file_response(state::ServerState, request, worker_id::String,
                              path::String, token::String)
    isempty(path) && return HTTP.Response(400, "missing path")
    token == worker_file_token(state, worker_id, path) ||
        return HTTP.Response(403, "invalid file token")
    try
        info = stat_worker_path(state, worker_id, path)
        info.isfile || return HTTP.Response(404, ["Cache-Control" => "no-store"],
                                            "file no longer exists on worker")
        mime = string(Bonito.file_mimetype(path))
        if !info.range_reads
            # Workers installed before range reads still work through the existing
            # transfer protocol. Upgrading them enables seeking without a full copy.
            return worker_file_copy_response(state, request, worker_id, path, info)
        end
        range = Bonito.parse_byte_range(HTTP.header(request, "Range", ""), info.size)
        if range === nothing && !isempty(HTTP.header(request, "Range", ""))
            return HTTP.Response(416, ["Content-Range" => "bytes */$(info.size)"])
        end
        start, stop = range === nothing ? (0, info.size - 1) : range
        body = UInt8[]
        sizehint!(body, stop - start + 1)
        offset = start
        while offset <= stop
            count = min(256 * 1024, stop - offset + 1)
            bytes = read_worker_file_range(state, worker_id, path, offset, count)
            length(bytes) == count || error("file changed while reading: $path")
            append!(body, bytes)
            offset += count
        end
        headers = ["Content-Type" => mime, "Cache-Control" => "no-cache",
                   "Accept-Ranges" => "bytes", "Content-Length" => string(length(body))]
        range === nothing || push!(headers, "Content-Range" => "bytes $start-$stop/$(info.size)")
        return HTTP.Response(range === nothing ? 200 : 206, headers; body)
    catch e
        e isa InterruptException && rethrow()
        @warn "worker file: read failed" worker_id path exception = (e, catch_backtrace())
        return HTTP.Response(502, ["Cache-Control" => "no-store"], "could not read file from worker")
    end
end

# /attachment/<pid>?file=<name> — serve a pasted/dropped image from the
# project's `.bt-attachments/` dir so user bubbles can render it INLINE
# (`msg_to_dict(::UserMsg)` builds these URLs). Unlike /download this reads
# the SERVER mirror directly — `save_attachment` wrote the file there, so no
# worker round-trip — and serves inline with the real image mime. `file` must
# be a bare filename; anything path-like is rejected (the attachment dir is
# the whole exposed surface). Filenames are timestamp+uuid — immutable — so
# the response is cacheable forever.
const ATTACHMENT_ROUTE_RE = r"^/attachment/([A-Za-z0-9_-]+)"

function attachment_response(state::ServerState, project_id::AbstractString,
                             file::AbstractString)
    occursin(r"^[A-Za-z0-9_-]+$", project_id) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "invalid project id\n")
    proj = get(state.projects[], project_id, nothing)
    proj === nothing &&
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "unknown project '$project_id'\n")
    # Bare, well-formed filename only — no separators, no dot-dot, one of the
    # extensions `save_attachment` can produce.
    occursin(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$", file) ||
        return HTTP.Response(403, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "invalid attachment name\n")
    mime = get(ATTACHMENT_MIME_BY_EXT, lowercase(lstrip(splitext(file)[2], '.')), nothing)
    mime === nothing &&
        return HTTP.Response(403, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "unsupported attachment type\n")
    path = joinpath(proj.server_path, ATTACHMENT_DIR_NAME, file)
    isfile(path) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "no such attachment\n")
    return HTTP.Response(200,
        ["Content-Type"  => mime,
         "Cache-Control" => "public, max-age=31536000, immutable"],
        body = read(path))
end

# Strip anything that could break (or smuggle a header into) the
# Content-Disposition filename. Keep it plain.
download_filename(name::AbstractString) =
    replace(String(name), r"[\"\r\n\\/]" => "_")

# Plain function (no live HTTP server needed) so tests can call it directly.
function download_response(state::ServerState, project_id::AbstractString,
                           path::AbstractString)
    occursin(r"^[A-Za-z0-9_-]+$", project_id) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "invalid project id\n")
    proj = get(state.projects[], project_id, nothing)
    proj === nothing &&
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "unknown project '$project_id'\n")
    isempty(path) &&
        return HTTP.Response(400, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "missing ?path\n")
    # Security: the requested path must resolve INSIDE the project's worker tree.
    wroot = normpath(String(proj.worker_path))
    npath = normpath(String(path))
    (npath == wroot || startswith(npath, wroot * "/")) ||
        return HTTP.Response(403, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "path is outside the project\n")
    tmp = tempname()
    try
        fetch_file_from_worker(state, proj.worker_id, npath, tmp; handoff_timeout = 120.0)
        data = read(tmp)
        return HTTP.Response(200,
            ["Content-Type"        => "application/octet-stream",
             "Content-Disposition" => "attachment; filename=\"$(download_filename(basename(npath)))\"",
             "Cache-Control"       => "no-cache"],
            body = data)
    catch e
        @warn "download: fetch from worker failed" project_id path exception = (e, catch_backtrace())
        return HTTP.Response(502, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "could not fetch file from worker\n")
    finally
        rm(tmp; force = true)
    end
end

esc_html(s::AbstractString) = replace(s,
    "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# Substitute the server URL + shared secret + git rev into a templated install
# script. install.jl guards against being run with the `{{ }}` placeholders
# intact, so a raw fetch of any asset (bypassing these routes) fails loudly.
function render_install_script(template::AbstractString,
                                 public_url::String, worker_secret::String)
    bonito_url, bonito_rev = current_bonito_install_spec()
    replace(template,
        "{{SERVER_URL}}"    => public_url,
        "{{WORKER_SECRET}}" => worker_secret,
        "{{REV}}"           => current_repo_rev(),
        "{{SOURCE_ID}}"     => current_repo_source_id(),
        "{{BONITO_URL}}"    => bonito_url,
        "{{BONITO_REV}}"    => bonito_rev,
    )
end

# The version identity sent to an installed worker after it authenticates on the
# control WebSocket. Keep it in terms of source specs, rather than a package
# version: workers and servers commonly run feature branches where every
# Project.toml says the same development version.
function current_worker_update_spec()
    bonito_url, bonito_rev = current_bonito_install_spec()
    return Dict(
        "repo"       => "https://github.com/SimonDanisch/BonitoAgents.jl",
        "rev"        => current_repo_rev(),
        "source_id"  => current_repo_source_id(),
        "bonito_url" => bonito_url,
        "bonito_rev" => bonito_rev,
    )
end

# A branch name cannot tell a worker whether it is on yesterday's `main` or
# today's. Prefer the server's reachable commit as its update identity and only
# fall back to the install ref when the deployment is not a usable git checkout.
function current_repo_source_id()
    ref = current_repo_rev()
    pkg = pkgdir(@__MODULE__)
    pkg === nothing && return ref
    repo_root = abspath(pkg, "..")
    ispath(joinpath(repo_root, ".git")) || return ref
    try
        sha = strip(read(`git -C $repo_root rev-parse HEAD`, String))
        return _sha_on_origin(repo_root, sha) ? String(sha) : ref
    catch e
        e isa InterruptException && rethrow()
        @debug "current_repo_source_id: git resolve failed" exception=e
        return ref
    end
end

"""
    current_repo_rev() -> String

Branch (or sha) the server is currently running from, used to template the
worker `install.jl` so a fresh `curl … | sh` lands the workers on the exact
same revision the server is serving. Lets a dev iterate on a feature branch
without users needing to know its name — they just re-run the curl one-liner.

Resolves in order:

  1. `BONITOAGENTS_INSTALL_REV` env var (escape hatch for ops who want to pin
     workers to a stable tag while running the server from `main`).
  2. The monorepo's checked-out branch (best-effort via `git rev-parse
     --abbrev-ref HEAD`; falls back to the exact sha when the repo is in
     detached-HEAD state).
  3. No git working tree (a release bundle, or installed via `Pkg.add`):
     the `v<version>` tag for a clean release version — a bundle is built
     FROM that tag (build-app.yml), so workers land on exactly the code the
     server runs. A prerelease/build-suffixed version (e.g. `0.2.0-DEV` on
     `main` between releases) can only guess `"main"`.

Called per request so a `git checkout` on the server side propagates to the
next worker install without restarting.
"""
function current_repo_rev()
    override = get(ENV, "BONITOAGENTS_INSTALL_REV", "")
    isempty(override) || return override

    pkg = pkgdir(@__MODULE__)
    pkg === nothing && return install_rev_for(pkgversion(@__MODULE__))
    # `pkgdir` returns `<monorepo>/BonitoAgents`; the monorepo (where `.git`
    # lives) is one level up. `.git` may be a directory (normal clone) or a
    # file (submodule / worktree); both count.
    repo_root = abspath(pkg, "..")
    return _git_head_ref_of(repo_root, install_rev_for(pkgversion(@__MODULE__)))
end

# The install rev for a git-less deployment, from the running package version:
# a clean release version maps to its `v<version>` tag (what release bundles
# are built from); a prerelease/build suffix or unknown version means "not a
# tagged release" — `main` is the only honest guess then.
install_rev_for(v::Union{VersionNumber,Nothing}) =
    v !== nothing && isempty(v.prerelease) && isempty(v.build) ? "v$(v)" : "main"

# Helper: best-effort `(branch | sha)` for a working-tree path that a worker's
# `Pkg.add(rev = …)` can ACTUALLY resolve against the remote. Returns `default`
# when the path isn't a git checkout, git refuses to answer, or nothing usable
# is reachable on origin.
#
# The subtlety: `git rev-parse --abbrev-ref HEAD` happily returns a branch name
# that only exists locally — e.g. a feature branch that was merged and DELETED on
# the remote. Templating that into the installer makes every worker install fail
# with "Did not find rev <branch>". So we only hand back the branch when origin
# still has it; otherwise the exact sha if THAT is reachable on origin; otherwise
# the caller's default (a `v<version>` tag or "main").
function _git_head_ref_of(path::AbstractString, default::AbstractString)
    ispath(joinpath(path, ".git")) || return default
    try
        branch = strip(read(`git -C $path rev-parse --abbrev-ref HEAD`, String))
        sha    = strip(read(`git -C $path rev-parse HEAD`, String))
        branch != "HEAD" && _branch_on_origin(path, branch) && return String(branch)
        _sha_on_origin(path, sha) && return String(sha)
        return default
    catch e
        @debug "_git_head_ref_of: git resolve failed" path exception=e
        return default
    end
end

# Does origin still publish this branch? Authoritative (a network `ls-remote`);
# on ANY failure (offline, git error) assume NO so we fall back to a safe ref
# rather than template a branch the worker can't fetch.
function _branch_on_origin(path::AbstractString, branch::AbstractString)
    try
        return !isempty(strip(read(`git -C $path ls-remote --heads origin $branch`, String)))
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

# Is this sha reachable from a remote-tracking branch (so `Pkg.add(rev=sha)` can
# fetch it)? `git branch -r` lists ONLY remote-tracking refs, so a non-empty
# result means some origin branch contains the commit. Fast (local refs).
function _sha_on_origin(path::AbstractString, sha::AbstractString)
    try
        return !isempty(strip(read(`git -C $path branch -r --contains $sha`, String)))
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

"""
    current_bonito_install_spec() -> (url::String, rev::String)

The `(url, rev)` pair the worker should pin Bonito at, so the worker's eval
sessions (which `BonitoMCP` proxies through) use the SAME Bonito version
the server ships its dashboard with — without that, a fresh worker installed
via `curl … | sh` resolves Bonito off the registry and the remote-app
protocol (proxy frames, dial-back, `id_prefix`) drifts vs. the server's.

Resolution order, mirroring `current_repo_rev`:

  1. `BONITOAGENTS_BONITO_URL` + `BONITOAGENTS_BONITO_REV` env vars
     (ops can pin workers to a published tag while the server itself
     dev-tracks a path).
  2. The active project's `[sources]` `Bonito = {url, rev}` literal
     (the normal case when the monorepo's Project.toml pins a feature
     branch).
  3. `[sources]` `Bonito = {path = "..."}` (the dev case where Bonito is
     dev'd next to the monorepo): walk into the path and derive
     `url = remote.origin.url`, `rev = current branch | sha`. This is
     what makes `git checkout` on the dev's Bonito propagate to workers.
  4. Fallback `(github.com/SimonDanisch/Bonito.jl, "main")`.
"""
function current_bonito_install_spec()
    url_env = get(ENV, "BONITOAGENTS_BONITO_URL", "")
    rev_env = get(ENV, "BONITOAGENTS_BONITO_REV", "")
    (!isempty(url_env) && !isempty(rev_env)) && return (url_env, rev_env)

    default_url = "https://github.com/SimonDanisch/Bonito.jl.git"
    default_rev = "master"
    bonito_uuid = Base.UUID("824d6782-a2ef-11e9-3a09-e5662e0c26f8")

    # 1. Project file `[sources]` literal — the common monorepo case.
    project_file = Base.active_project()
    if project_file !== nothing
        try
            proj = Pkg.Types.read_project(project_file)
            src = get(proj.sources, "Bonito", nothing)
            if src !== nothing && haskey(src, "url")
                return (String(src["url"]),
                        String(get(src, "rev", default_rev)))
            elseif src !== nothing && haskey(src, "path")
                p = String(src["path"])
                abs_p = isabspath(p) ? p :
                        normpath(joinpath(dirname(project_file), p))
                got = _spec_from_git_path(abs_p, default_url, default_rev)
                got === nothing || return got
            end
        catch e
            @debug "current_bonito_install_spec: read_project failed" exception=e
        end
    end

    # 2. Manifest's resolved Bonito entry. Covers two cases the `[sources]`
    # path above misses: (a) the outer dev project Pkg.develop'd Bonito so
    # there's no project-level `[sources]` block, only a path in the
    # manifest; (b) Bonito is `Pkg.add`'d directly from a git url+rev (so
    # `git_source` / `git_revision` come through populated). For path-tracked,
    # walk the working tree the same way as the `[sources]` path branch.
    try
        deps = Pkg.dependencies()
        if haskey(deps, bonito_uuid)
            info = deps[bonito_uuid]
            if info.git_source !== nothing && info.git_revision !== nothing
                return (String(info.git_source), String(info.git_revision))
            end
            if info.is_tracking_path && info.source isa AbstractString
                got = _spec_from_git_path(String(info.source),
                                          default_url, default_rev)
                got === nothing || return got
            end
        end
    catch e
        @debug "current_bonito_install_spec: dependencies probe failed" exception=e
    end

    return (default_url, default_rev)
end

# Resolve a working-tree path into a `(remote_url, branch_or_sha)` pair.
# Returns `nothing` if the path isn't a usable git checkout — callers fall
# back to their own defaults.
function _spec_from_git_path(path::AbstractString,
                              default_url::AbstractString,
                              default_rev::AbstractString)
    isdir(path) || return nothing
    try
        remote = strip(read(`git -C $path config --get remote.origin.url`, String))
        rev    = _git_head_ref_of(path, default_rev)
        url    = isempty(remote) ? default_url : String(remote)
        return (url, rev)
    catch e
        @debug "_spec_from_git_path: probe failed" path exception=e
        return nothing
    end
end

# WebSocket routes (worker-side connection terminus). Each closure captures
# `state` so the route handler picks up the same instance the dashboard reads
# from / the chat writes into.
function add_worker_ws_routes!(srv::Bonito.Server, state::ServerState)
    Bonito.HTTPServer.websocket_route!(srv, "/worker-ws"   => (_ctx, ws) ->
        handle_worker_control(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/worker-acp"  => (_ctx, ws) ->
        handle_worker_acp(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/transfer-ws" => (_ctx, ws) ->
        handle_transfer_ws(state, ws))
    # Eval workers (BonitoMCP) dial here to be driven for interactive app proxying.
    Bonito.HTTPServer.websocket_route!(srv, "/eval-ws" => (_ctx, ws) ->
        handle_eval_ws(state, ws))
    # The BonitoMCP stdio process itself dials here — the control channel the
    # per-tool eval interrupt rides on (see remote_app.jl `MCP_CTRL`).
    Bonito.HTTPServer.websocket_route!(srv, "/mcp-ws" => (_ctx, ws) ->
        handle_mcp_ctrl_ws(state, ws))
end
